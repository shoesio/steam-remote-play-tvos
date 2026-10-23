#import "CNMoonlightVideoRenderer.h"

// Solarflare now owns PyroWave bitrate adaptation after the client opts in via
// RTSP. The former Punktfunk client feedback packet reused control type 0x5510,
// which Solarflare now defines as phase-offset pacing, so it must never be sent
// as a bitrate command. Keep the old renderer's optional controller inert until
// it is replaced with Solarflare's host-managed telemetry model.
#define PYROWAVE_RATE_PRESSURE_CADENCE 0x0001
#define PYROWAVE_RATE_PRESSURE_DECODER 0x0002
#define PYROWAVE_RATE_PRESSURE_NETWORK 0x0004
#define PYROWAVE_RATE_PRESSURE_ASSEMBLY 0x0008
static int LiSendPyroWaveRateControl(uint32_t targetBitrateKbps,
                                    uint32_t ceilingBitrateKbps,
                                    uint16_t deliveredFpsX100,
                                    uint16_t pressureFlags) {
    (void)targetBitrateKbps;
    (void)ceilingBitrateKbps;
    (void)deliveredFpsX100;
    (void)pressureFlags;
    return -1;
}

static uint32_t LiGetNetworkDroppedVideoFrameCount(void) {
    return 0;
}
#import "CNMoonlightPyroWaveDecoder.h"
#import "CNPyroWaveGPUFrame.h"

#include <math.h>

@import AVFoundation;
@import QuartzCore;

@interface CNMoonlightVideoRenderer ()
@property (nonatomic, weak) CNMoonlightVideoView *videoView;
@property (nonatomic, strong) NSMutableArray<NSData *> *parameterSets;
@property (nonatomic, assign) CMVideoFormatDescriptionRef formatDescription;
@property (nonatomic, assign) int videoFormat;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) BOOL useFramePacing;
@property (atomic, assign) BOOL needsIdrAfterDisplayLayerReset;
@property (nonatomic, strong) CNMoonlightPyroWaveDecoder *pyroWaveDecoder;
@property (nonatomic, assign) BOOL didLogPyroWaveDecoderStatus;
@property (nonatomic, assign) BOOL didLogPyroWaveDecodedFrame;
@property (nonatomic, assign) NSUInteger pyroWaveFallbackCount;
@property (nonatomic, strong) dispatch_queue_t pyroWavePresentationQueue;
@property (atomic, assign) BOOL displayEnqueuePending;
@property (nonatomic, assign) NSUInteger displayEnqueueDropCount;
@property (nonatomic, assign) BOOL adaptiveBitrateEnabled;
@property (nonatomic, assign) NSInteger adaptiveBitrateCeilingKbps;
@property (nonatomic, assign) NSInteger adaptiveBitrateProbeCeilingKbps;
@property (nonatomic, assign) NSInteger adaptiveBitrateFloorKbps;
@property (nonatomic, assign) NSInteger adaptiveBitrateCurrentKbps;
@property (nonatomic, assign) NSInteger adaptiveTargetFPS;
@property (nonatomic, assign) BOOL adaptiveIs4K;
@property (nonatomic, strong) dispatch_source_t adaptiveBitrateTimer;
@property (nonatomic, strong) dispatch_queue_t adaptiveBitrateQueue;
@property (nonatomic, assign) uint64_t adaptiveCompletedFrames;
@property (nonatomic, assign) uint64_t adaptiveDroppedFrames;
@property (nonatomic, assign) uint64_t adaptiveAssemblySamples;
@property (nonatomic, assign) uint64_t adaptiveAssemblyTotalUs;
@property (nonatomic, assign) uint64_t adaptiveAssemblyMaxUs;
@property (nonatomic, assign) uint64_t adaptiveLastCompletedFrames;
@property (nonatomic, assign) uint64_t adaptiveLastDroppedFrames;
@property (nonatomic, assign) uint64_t adaptiveLastAssemblySamples;
@property (nonatomic, assign) uint64_t adaptiveLastAssemblyTotalUs;
@property (nonatomic, assign) uint32_t adaptiveLastFecFailed;
@property (nonatomic, assign) uint32_t adaptiveLastNetworkDroppedFrames;
@property (nonatomic, assign) CFTimeInterval adaptiveLastSampleTime;
@property (nonatomic, assign) NSUInteger adaptiveHealthyWindows;
@property (nonatomic, assign) NSUInteger adaptiveWindowCount;
@property (nonatomic, assign) BOOL adaptiveHasBaseline;
@end

@implementation CNMoonlightVideoRenderer

#define NALU_START_PREFIX_SIZE 3
#define NAL_LENGTH_PREFIX_SIZE 4

- (instancetype)initWithVideoView:(CNMoonlightVideoView *)videoView
                    useFramePacing:(BOOL)useFramePacing
           adaptiveBitrateEnabled:(BOOL)adaptiveBitrateEnabled
                bitrateCeilingKbps:(NSInteger)bitrateCeilingKbps
                         targetFPS:(NSInteger)targetFPS {
    self = [super init];
    if (self) {
        _videoView = videoView;
        _useFramePacing = useFramePacing;
        _adaptiveBitrateEnabled = adaptiveBitrateEnabled;
        _adaptiveBitrateCeilingKbps = MAX(25 * 1000, bitrateCeilingKbps);
        _adaptiveBitrateCurrentKbps = _adaptiveBitrateCeilingKbps;
        _adaptiveTargetFPS = MAX(30, targetFPS);
        _parameterSets = [NSMutableArray array];
        _pyroWavePresentationQueue = dispatch_queue_create("com.cloudnow.pyrowave.presentation", DISPATCH_QUEUE_SERIAL);
        _adaptiveBitrateQueue = dispatch_queue_create("com.cloudnow.pyrowave.adaptive-bitrate", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    [self cleanup];
}

- (int)setupWithVideoFormat:(int)videoFormat width:(int)width height:(int)height redrawRate:(int)redrawRate {
    self.videoFormat = videoFormat;
    self.needsIdrAfterDisplayLayerReset = NO;
    [self.parameterSets removeAllObjects];
    self.pyroWaveDecoder = nil;
    self.didLogPyroWaveDecoderStatus = NO;
    self.didLogPyroWaveDecodedFrame = NO;
    self.pyroWaveFallbackCount = 0;
    if (self.formatDescription) {
        CFRelease(self.formatDescription);
        self.formatDescription = NULL;
    }

    if (videoFormat & VIDEO_FORMAT_MASK_PYROWAVE) {
        self.adaptiveIs4K = width >= 3840 || height >= 2160;
        if (width >= 3840 || height >= 2160) {
            // Detailed 4K60 gameplay saturates the requested rate even though
            // quiet menus do not. Begin at the measured safe point, retain the
            // ability to retreat when the A12 decoder or LAN receive queue
            // reports pressure, and cautiously probe all the way to the user's
            // selected ceiling while conditions remain clean.
            self.adaptiveBitrateFloorKbps = 100 * 1000;
            self.adaptiveBitrateProbeCeilingKbps = self.adaptiveBitrateCeilingKbps;
        } else if (width >= 2560 || height >= 1440) {
            self.adaptiveBitrateFloorKbps = 150 * 1000;
        } else if (width >= 1920 || height >= 1080) {
            self.adaptiveBitrateFloorKbps = 100 * 1000;
        } else {
            self.adaptiveBitrateFloorKbps = 50 * 1000;
        }
        self.adaptiveBitrateFloorKbps = MIN(self.adaptiveBitrateFloorKbps, self.adaptiveBitrateCeilingKbps);
        if (!self.adaptiveIs4K) {
            self.adaptiveBitrateProbeCeilingKbps = self.adaptiveBitrateCeilingKbps;
        }
        self.pyroWaveDecoder = [[CNMoonlightPyroWaveDecoder alloc] initWithWidth:width height:height];
        NSString *status = self.pyroWaveDecoder.statusMessage;
        NSLog(@"[CNMoonlightVideoRenderer] PyroWave setup status='%@' available=%d format=0x%x size=%dx%d redraw=%d",
              status,
              self.pyroWaveDecoder.isAvailable,
              videoFormat,
              width,
              height,
              redrawRate);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.videoView configureVideoWidth:width height:height];
            if (self.pyroWaveDecoder.isGPUPathAvailable) {
                [self.videoView prepareForPyroWaveMetalRendering];
            } else {
                [self.videoView resetDisplayLayer];
            }
            [self.videoView recordRendererEvent:status.length > 0 ? status : @"Receiving PyroWave stream"];
        });
        return DR_OK;
    }

    if ((videoFormat & VIDEO_FORMAT_MASK_H264) == 0) {
        return DR_NEED_IDR;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.videoView configureVideoWidth:width height:height];
        [self.videoView resetDisplayLayer];
        [self.videoView recordRendererEvent:@"Waiting for video keyframe"];
    });
    return DR_OK;
}

- (void)start {
    self.running = YES;
    [self startAdaptiveBitrateControllerIfNeeded];
}

- (void)stop {
    self.running = NO;
    [self stopAdaptiveBitrateController];
}

- (void)cleanup {
    self.running = NO;
    [self stopAdaptiveBitrateController];
    [self.parameterSets removeAllObjects];
    CNMoonlightPyroWaveDecoder *retiringDecoder = self.pyroWaveDecoder;
    self.pyroWaveDecoder = nil;
    if (retiringDecoder && self.pyroWavePresentationQueue) {
        // Do not synchronously wait here: nextDrawable may be applying
        // backpressure, and cleanup can run on the tvOS main thread. A tail
        // block keeps the decoder and its Vulkan images alive until all queued
        // presentation blocks have returned. Releasing it there invokes the
        // decoder's shared GPU-queue drain after their Metal commits.
        dispatch_async(self.pyroWavePresentationQueue, ^{
            __attribute__((objc_precise_lifetime)) CNMoonlightPyroWaveDecoder *decoderLifetime = retiringDecoder;
            (void)decoderLifetime;
        });
    }
    if (self.formatDescription) {
        CFRelease(self.formatDescription);
        self.formatDescription = NULL;
    }
}

- (int)submitDecodeUnit:(PDECODE_UNIT)decodeUnit {
    if (!self.running || !decodeUnit) {
        return DR_OK;
    }

    if (self.videoFormat & VIDEO_FORMAT_MASK_PYROWAVE) {
        uint64_t assemblyUs = 0;
        if (decodeUnit->enqueueTimeUs >= decodeUnit->receiveTimeUs) {
            assemblyUs = decodeUnit->enqueueTimeUs - decodeUnit->receiveTimeUs;
        }
        @synchronized (self) {
            if (assemblyUs > 0) {
                self.adaptiveAssemblySamples += 1;
                self.adaptiveAssemblyTotalUs += assemblyUs;
                self.adaptiveAssemblyMaxUs = MAX(self.adaptiveAssemblyMaxUs, assemblyUs);
            }
        }
        BOOL isIDR = decodeUnit->frameType == FRAME_TYPE_IDR;
        const uint32_t rtpTimestamp = decodeUnit->rtpTimestamp;
        const int frameType = decodeUnit->frameType;
        const int fullLength = decodeUnit->fullLength;
        __weak typeof(self) weakSelf = self;
        [self.pyroWaveDecoder submitDecodeUnit:decodeUnit GPUFrameCompletion:^(CNPyroWaveGPUFrame *GPUFrame,
                                                                              CMSampleBufferRef sampleBuffer,
                                                                              NSString *error) {
            CNMoonlightVideoRenderer *strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.running) {
                [GPUFrame markPresentationCompleteAtTime:CACurrentMediaTime()];
                if (sampleBuffer) {
                    CFRelease(sampleBuffer);
                }
                return;
            }

            if (GPUFrame) {
                @synchronized (strongSelf) {
                    strongSelf.adaptiveCompletedFrames += 1;
                }
                dispatch_async(strongSelf.pyroWavePresentationQueue, ^{
                    @autoreleasepool {
                    if (!strongSelf.running || !strongSelf.videoView) {
                        [GPUFrame markPresentationCompleteAtTime:CACurrentMediaTime()];
                        return;
                    }
                    NSString *renderError = nil;
                    if (![strongSelf.videoView displayPyroWaveGPUFrame:GPUFrame error:&renderError]) {
                        @synchronized (strongSelf) {
                            strongSelf.adaptiveDroppedFrames += 1;
                        }
                        if (renderError.length > 0 && strongSelf.pyroWaveFallbackCount++ % 120 == 0) {
                            NSLog(@"[CNMoonlightVideoRenderer] PyroWave Metal frame dropped: %@", renderError);
                        }
                    }
                    }
                });
                return;
            }

            if (sampleBuffer) {
                @synchronized (strongSelf) {
                    strongSelf.adaptiveCompletedFrames += 1;
                }
                if (!strongSelf.didLogPyroWaveDecodedFrame) {
                    strongSelf.didLogPyroWaveDecodedFrame = YES;
                    NSLog(@"[CNMoonlightVideoRenderer] PyroWave decoded sample buffer rtp=%u frameType=%d fullLength=%d",
                          rtpTimestamp,
                          frameType,
                          fullLength);
                }
                [strongSelf enqueueSampleBuffer:sampleBuffer decodedEvent:@"PyroWave frame decoded"];
                return;
            }

            if ([error containsString:@"accumulating packets"]
                || [error containsString:@"overload"]
                || [error containsString:@"GPU frame ring is full"]) {
                // These are bounded newest-frame drops, not decoder failures.
                // Avoid adding UI work precisely when presentation is under
                // pressure; the decoder's rate-limited perf log counts them.
                @synchronized (strongSelf) {
                    strongSelf.adaptiveDroppedFrames += 1;
                }
                return;
            }

            // A bounded pixel-buffer pool drops a completed frame when the
            // display layer still owns every buffer. That is normal pressure,
            // not a decoder fault, and must not create more main-thread work.
            if (error.length == 0) {
                return;
            }

            if (!strongSelf.didLogPyroWaveDecoderStatus && error.length > 0) {
                strongSelf.didLogPyroWaveDecoderStatus = YES;
                NSLog(@"[CNMoonlightVideoRenderer] PyroWave decoder unavailable: %@", error);
            }

            NSString *event = error.length > 0 ? error : @"PyroWave frame received";
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf.videoView recordDecodeUnitWithIDR:isIDR];
                [strongSelf.videoView recordRendererEvent:event];
            });
        }];
        return DR_OK;
    }

    if ((self.videoFormat & VIDEO_FORMAT_MASK_H264) == 0) {
        return DR_NEED_IDR;
    }

    unsigned char *pictureData = malloc((size_t)decodeUnit->fullLength);
    if (!pictureData) {
        return DR_NEED_IDR;
    }

    int offset = 0;
    BOOL hasPictureData = NO;
    for (PLENTRY entry = decodeUnit->bufferList; entry != NULL; entry = entry->next) {
        if (entry->bufferType != BUFFER_TYPE_PICDATA) {
            int result = [self submitDecodeBuffer:(unsigned char *)entry->data
                                           length:entry->length
                                       bufferType:entry->bufferType
                                       decodeUnit:decodeUnit];
            if (result != DR_OK) {
                free(pictureData);
                return result;
            }
        } else {
            hasPictureData = YES;
            memcpy(pictureData + offset, entry->data, (size_t)entry->length);
            offset += entry->length;
        }
    }

    if (!hasPictureData || offset <= 0) {
        free(pictureData);
        return DR_OK;
    }

    return [self submitDecodeBuffer:pictureData
                             length:offset
                         bufferType:BUFFER_TYPE_PICDATA
                         decodeUnit:decodeUnit];
}

- (int)submitDecodeBuffer:(unsigned char *)data
                   length:(int)length
               bufferType:(int)bufferType
               decodeUnit:(PDECODE_UNIT)decodeUnit {
    if (decodeUnit->frameType == FRAME_TYPE_IDR) {
        if (bufferType != BUFFER_TYPE_PICDATA) {
            if (bufferType == BUFFER_TYPE_VPS || bufferType == BUFFER_TYPE_SPS || bufferType == BUFFER_TYPE_PPS) {
                NSData *parameterSet = [self parameterSetFromData:data length:length];
                if (parameterSet.length > 0) {
                    [self.parameterSets addObject:parameterSet];
                }
            }
            return DR_OK;
        }

        [self rebuildFormatDescriptionIfPossible];
    }

    BOOL isIDR = decodeUnit->frameType == FRAME_TYPE_IDR;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.videoView recordDecodeUnitWithIDR:isIDR];
    });

    if (!self.formatDescription) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.videoView recordRendererEvent:@"Waiting for H.264 parameter sets"];
        });
        free(data);
        return DR_NEED_IDR;
    }

    if (self.needsIdrAfterDisplayLayerReset) {
        self.needsIdrAfterDisplayLayerReset = NO;
        free(data);
        return DR_NEED_IDR;
    }

    CMSampleBufferRef sampleBuffer = [self sampleBufferForPictureData:data length:length decodeUnit:decodeUnit];
    if (!sampleBuffer) {
        return DR_NEED_IDR;
    }

    [self enqueueSampleBuffer:sampleBuffer decodedEvent:nil];
    return DR_OK;
}

- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer decodedEvent:(NSString *)decodedEvent {
    if (!self.useFramePacing) {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, YES);
        if (attachments && CFArrayGetCount(attachments) > 0) {
            CFMutableDictionaryRef attachment = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
            CFDictionarySetValue(attachment, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        }
    }

    @synchronized (self) {
        if (self.displayEnqueuePending) {
            self.displayEnqueueDropCount += 1;
            if (self.displayEnqueueDropCount % 60 == 1) {
                NSLog(@"[CNMoonlightVideoRenderer] Dropping video frame while the presentation queue catches up (drops=%lu)",
                      (unsigned long)self.displayEnqueueDropCount);
            }
            CFRelease(sampleBuffer);
            return;
        }
        self.displayEnqueuePending = YES;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized (self) {
            self.displayEnqueuePending = NO;
        }

        CNMoonlightVideoView *view = self.videoView;
        if (!view) {
            CFRelease(sampleBuffer);
            return;
        }

        AVSampleBufferDisplayLayer *displayLayer = view.displayLayer;
        if (!displayLayer) {
            [view recordRendererEvent:@"Waiting for display layer"];
            CFRelease(sampleBuffer);
            return;
        }

        if (displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
            NSError *layerError = displayLayer.error;
            NSLog(@"[CNMoonlightVideoRenderer] Display layer failed during enqueue: %@", layerError);
            [view resetDisplayLayer];
            [view recordDisplayLayerResetWithReason:@"Display layer failed during enqueue"];
            self.needsIdrAfterDisplayLayerReset = YES;
            CFRelease(sampleBuffer);
            return;
        }

        if (!displayLayer.isReadyForMoreMediaData) {
            self.displayEnqueueDropCount += 1;
            if (self.displayEnqueueDropCount % 60 == 1) {
                NSLog(@"[CNMoonlightVideoRenderer] Dropping video frame because the display layer is back-pressured (drops=%lu)",
                      (unsigned long)self.displayEnqueueDropCount);
            }
            CFRelease(sampleBuffer);
            return;
        }

        [displayLayer enqueueSampleBuffer:sampleBuffer];
        displayLayer.hidden = NO;
        [view recordSampleBufferEnqueued];
        if (decodedEvent.length > 0) {
            [view recordRendererEvent:decodedEvent];
        }
        CFRelease(sampleBuffer);
    });
}

- (void)startAdaptiveBitrateControllerIfNeeded {
    if (!self.adaptiveBitrateEnabled
        || !(self.videoFormat & VIDEO_FORMAT_MASK_PYROWAVE)
        || self.adaptiveBitrateTimer) {
        return;
    }

    // 4K at the manual ceiling can exceed the receiver/network queue before
    // feedback has a chance to react. Start Auto from a known-safe point and
    // probe upward. Manual bitrate remains unchanged.
    NSInteger initialKbps = self.adaptiveIs4K
        ? MIN(self.adaptiveBitrateProbeCeilingKbps, 200 * 1000)
        : self.adaptiveBitrateProbeCeilingKbps;
    self.adaptiveBitrateCurrentKbps = initialKbps;
    self.adaptiveHealthyWindows = 0;
    self.adaptiveWindowCount = 0;
    self.adaptiveHasBaseline = NO;

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.adaptiveBitrateQueue);
    self.adaptiveBitrateTimer = timer;
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                              2 * NSEC_PER_SEC,
                              200 * NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf sampleAdaptiveBitrate];
    });
    dispatch_resume(timer);
    int initialSendResult = 0;
    if (initialKbps < self.adaptiveBitrateCeilingKbps) {
        initialSendResult = LiSendPyroWaveRateControl((uint32_t)initialKbps,
                                                     (uint32_t)self.adaptiveBitrateCeilingKbps,
                                                     0,
                                                     0);
    }
    NSLog(@"[CNMoonlightAdaptiveBitrate] enabled target=%ldfps initial=%ldMbps floor=%ldMbps autoCeiling=%ldMbps manualCeiling=%ldMbps initialSend=%d",
          (long)self.adaptiveTargetFPS,
          (long)(initialKbps / 1000),
          (long)(self.adaptiveBitrateFloorKbps / 1000),
          (long)(self.adaptiveBitrateProbeCeilingKbps / 1000),
          (long)(self.adaptiveBitrateCeilingKbps / 1000),
          initialSendResult);
}

- (void)stopAdaptiveBitrateController {
    dispatch_source_t timer = self.adaptiveBitrateTimer;
    self.adaptiveBitrateTimer = nil;
    if (timer) {
        dispatch_source_cancel(timer);
    }
}

- (void)sampleAdaptiveBitrate {
    if (!self.running || !self.adaptiveBitrateEnabled || !(self.videoFormat & VIDEO_FORMAT_MASK_PYROWAVE)) {
        return;
    }

    uint64_t completed = 0;
    uint64_t dropped = 0;
    uint64_t assemblySamples = 0;
    uint64_t assemblyTotalUs = 0;
    uint64_t assemblyMaxUs = 0;
    @synchronized (self) {
        completed = self.adaptiveCompletedFrames;
        dropped = self.adaptiveDroppedFrames;
        assemblySamples = self.adaptiveAssemblySamples;
        assemblyTotalUs = self.adaptiveAssemblyTotalUs;
        assemblyMaxUs = self.adaptiveAssemblyMaxUs;
        self.adaptiveAssemblyMaxUs = 0;
    }

    RTP_VIDEO_STATS videoStats = {0};
    const RTP_VIDEO_STATS *stats = LiGetRTPVideoStats();
    if (stats) {
        videoStats = *stats;
    }

    CFTimeInterval now = CACurrentMediaTime();
    if (!self.adaptiveHasBaseline) {
        self.adaptiveHasBaseline = YES;
        self.adaptiveLastSampleTime = now;
        self.adaptiveLastCompletedFrames = completed;
        self.adaptiveLastDroppedFrames = dropped;
        self.adaptiveLastAssemblySamples = assemblySamples;
        self.adaptiveLastAssemblyTotalUs = assemblyTotalUs;
        self.adaptiveLastFecFailed = videoStats.packetCountFecFailed;
        self.adaptiveLastNetworkDroppedFrames = LiGetNetworkDroppedVideoFrameCount();
        return;
    }

    CFTimeInterval elapsed = MAX(0.25, now - self.adaptiveLastSampleTime);
    uint64_t completedDelta = completed - self.adaptiveLastCompletedFrames;
    uint64_t droppedDelta = dropped - self.adaptiveLastDroppedFrames;
    uint64_t assemblySampleDelta = assemblySamples - self.adaptiveLastAssemblySamples;
    uint64_t assemblyTotalDeltaUs = assemblyTotalUs - self.adaptiveLastAssemblyTotalUs;
    uint32_t fecFailedDelta = videoStats.packetCountFecFailed - self.adaptiveLastFecFailed;
    uint32_t networkDroppedFrames = LiGetNetworkDroppedVideoFrameCount();
    uint32_t networkDroppedDelta = networkDroppedFrames - self.adaptiveLastNetworkDroppedFrames;
    double deliveredFPS = (double)completedDelta / elapsed;
    double assemblyAverageMs = assemblySampleDelta > 0
        ? ((double)assemblyTotalDeltaUs / (double)assemblySampleDelta) / 1000.0
        : 0.0;
    double assemblyMaxMs = (double)assemblyMaxUs / 1000.0;
    double frameIntervalMs = 1000.0 / (double)MAX(1, self.adaptiveTargetFPS);

    uint16_t pressureFlags = 0;
    if (deliveredFPS < (double)self.adaptiveTargetFPS * 0.97) {
        pressureFlags |= PYROWAVE_RATE_PRESSURE_CADENCE;
    }
    if (droppedDelta > 0) {
        pressureFlags |= PYROWAVE_RATE_PRESSURE_DECODER;
    }
    if (fecFailedDelta > 0 || networkDroppedDelta > 0) {
        pressureFlags |= PYROWAVE_RATE_PRESSURE_NETWORK;
    }
    if ((assemblyAverageMs > frameIntervalMs * 0.75)
        || (assemblyMaxMs > frameIntervalMs * 2.0)) {
        pressureFlags |= PYROWAVE_RATE_PRESSURE_ASSEMBLY;
    }

    NSInteger previousKbps = self.adaptiveBitrateCurrentKbps;
    NSInteger nextKbps = previousKbps;
    const NSInteger stepKbps = 25 * 1000;
    // At 4K the A12 decoder is resolution/fragment-work bound. Live testing
    // showed the same ring pressure after halving the requested bitrate from
    // 200 to 100 Mbps, with zero network loss and sub-millisecond assembly.
    // Keep decoder pressure as a probe/recovery brake and diagnostic signal,
    // but do not discard image quality in response to a pressure source that
    // bitrate cannot relieve. Network and assembly pressure remain actionable.
    uint16_t nonActionablePressure = PYROWAVE_RATE_PRESSURE_CADENCE;
    if (self.adaptiveIs4K) {
        nonActionablePressure |= PYROWAVE_RATE_PRESSURE_DECODER;
    }
    uint16_t actionablePressure = pressureFlags & ~nonActionablePressure;
    if (actionablePressure != 0) {
        double factor = 0.85;
        if (pressureFlags & PYROWAVE_RATE_PRESSURE_NETWORK) {
            factor = 0.75;
        } else if (pressureFlags & PYROWAVE_RATE_PRESSURE_DECODER) {
            factor = droppedDelta >= 5 ? 0.70 : 0.80;
        } else if (pressureFlags & PYROWAVE_RATE_PRESSURE_ASSEMBLY) {
            factor = 0.80;
        }
        nextKbps = (NSInteger)floor(((double)previousKbps * factor) / (double)stepKbps) * stepKbps;
        nextKbps = MAX(self.adaptiveBitrateFloorKbps, nextKbps);
        self.adaptiveHealthyWindows = 0;
    } else if ((self.adaptiveIs4K
                    ? (actionablePressure == 0
                       && deliveredFPS >= (double)self.adaptiveTargetFPS * 0.95)
                    : (pressureFlags == 0
                       && deliveredFPS >= (double)self.adaptiveTargetFPS * 0.985
                       && (assemblyAverageMs == 0.0 || assemblyAverageMs < frameIntervalMs * 0.65)))) {
        // At 4K, recover quality once the transport has remained clean even
        // if resolution-bound cadence or decoder-ring pressure persists.
        // Lowering bitrate did not improve either signal in live testing; it
        // only left Auto pinned at visibly poor quality after a transient LAN
        // event. Any renewed network/assembly pressure still backs off at the
        // next two-second sample.
        self.adaptiveHealthyWindows += 1;
        NSUInteger recoveryWindows = self.adaptiveIs4K
            ? (previousKbps >= 200 * 1000 ? 15 : 10)
            : 3;
        if (self.adaptiveHealthyWindows >= recoveryWindows) {
            nextKbps = MIN(self.adaptiveBitrateProbeCeilingKbps, previousKbps + stepKbps);
            self.adaptiveHealthyWindows = 0;
        }
    } else {
        self.adaptiveHealthyWindows = 0;
    }

    self.adaptiveWindowCount += 1;
    if (nextKbps != previousKbps) {
        uint16_t deliveredFpsX100 = (uint16_t)MIN(UINT16_MAX, MAX(0, lround(deliveredFPS * 100.0)));
        int result = LiSendPyroWaveRateControl((uint32_t)nextKbps,
                                              (uint32_t)self.adaptiveBitrateCeilingKbps,
                                              deliveredFpsX100,
                                              pressureFlags);
        if (result == 0) {
            self.adaptiveBitrateCurrentKbps = nextKbps;
        }
        NSLog(@"[CNMoonlightAdaptiveBitrate] %@ %ld->%ldMbps delivered=%.2ffps decoderDrops=%llu networkDropped=%u fecFailed=%u assembly=%.2f/%.2fms pressure=0x%04x send=%d",
              nextKbps < previousKbps ? @"decrease" : @"increase",
              (long)(previousKbps / 1000),
              (long)(nextKbps / 1000),
              deliveredFPS,
              (unsigned long long)droppedDelta,
              networkDroppedDelta,
              fecFailedDelta,
              assemblyAverageMs,
              assemblyMaxMs,
              pressureFlags,
              result);
    } else if (self.adaptiveWindowCount % 5 == 0) {
        NSLog(@"[CNMoonlightAdaptiveBitrate] hold=%ldMbps delivered=%.2ffps decoderDrops=%llu networkDropped=%u fecFailed=%u assembly=%.2f/%.2fms pressure=0x%04x",
              (long)(previousKbps / 1000),
              deliveredFPS,
              (unsigned long long)droppedDelta,
              networkDroppedDelta,
              fecFailedDelta,
              assemblyAverageMs,
              assemblyMaxMs,
              pressureFlags);
    }

    self.adaptiveLastSampleTime = now;
    self.adaptiveLastCompletedFrames = completed;
    self.adaptiveLastDroppedFrames = dropped;
    self.adaptiveLastAssemblySamples = assemblySamples;
    self.adaptiveLastAssemblyTotalUs = assemblyTotalUs;
    self.adaptiveLastFecFailed = videoStats.packetCountFecFailed;
    self.adaptiveLastNetworkDroppedFrames = networkDroppedFrames;
}

- (NSData *)parameterSetFromData:(unsigned char *)data length:(int)length {
    int prefixLength = [self startCodeLengthForData:(const unsigned char *)data length:length atOffset:0];
    if (prefixLength <= 0 || length <= prefixLength) {
        return nil;
    }
    return [NSData dataWithBytes:data + prefixLength length:(NSUInteger)(length - prefixLength)];
}

- (void)rebuildFormatDescriptionIfPossible {
    if (self.parameterSets.count < 2) {
        return;
    }

    if (self.formatDescription) {
        CFRelease(self.formatDescription);
        self.formatDescription = NULL;
    }

    size_t parameterSetCount = self.parameterSets.count;
    const uint8_t *parameterSetPointers[parameterSetCount];
    size_t parameterSetSizes[parameterSetCount];
    for (NSUInteger index = 0; index < self.parameterSets.count; index++) {
        NSData *parameterSet = self.parameterSets[index];
        parameterSetPointers[index] = parameterSet.bytes;
        parameterSetSizes[index] = parameterSet.length;
    }

    OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        kCFAllocatorDefault,
        parameterSetCount,
        parameterSetPointers,
        parameterSetSizes,
        4,
        &_formatDescription
    );
    [self.parameterSets removeAllObjects];

    if (status != noErr) {
        self.formatDescription = NULL;
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.videoView recordRendererEvent:@"Video format description ready"];
    });
}

- (CMSampleBufferRef)sampleBufferForPictureData:(unsigned char *)data length:(int)length decodeUnit:(PDECODE_UNIT)decodeUnit {
    CMBlockBufferRef dataBlock = NULL;
    CMBlockBufferRef frameBlock = NULL;
    CMSampleBufferRef sampleBuffer = NULL;

    OSStatus status = CMBlockBufferCreateWithMemoryBlock(
        NULL,
        data,
        (size_t)length,
        kCFAllocatorDefault,
        NULL,
        0,
        (size_t)length,
        0,
        &dataBlock
    );
    if (status != noErr) {
        free(data);
        return NULL;
    }

    status = CMBlockBufferCreateEmpty(NULL, 0, 0, &frameBlock);
    if (status != noErr) {
        CFRelease(dataBlock);
        return NULL;
    }

    status = [self appendUpstreamLengthPrefixedNALUsFromData:data length:length dataBlock:dataBlock frameBlock:frameBlock];
    if (status != noErr) {
        CFRelease(dataBlock);
        CFRelease(frameBlock);
        return NULL;
    }

    CMTime presentationTime = decodeUnit->presentationTimeUs > 0
        ? CMTimeMake((int64_t)decodeUnit->presentationTimeUs, 1000000)
        : CMTimeMake((int64_t)decodeUnit->rtpTimestamp, 90000);
    CMSampleTimingInfo timing = {
        kCMTimeInvalid,
        presentationTime,
        kCMTimeInvalid
    };
    size_t sampleSize = CMBlockBufferGetDataLength(frameBlock);
    const size_t sampleSizes[] = { sampleSize };
    status = CMSampleBufferCreateReady(
        kCFAllocatorDefault,
        frameBlock,
        self.formatDescription,
        1,
        1,
        &timing,
        1,
        sampleSizes,
        &sampleBuffer
    );

    CFRelease(dataBlock);
    CFRelease(frameBlock);

    return status == noErr ? sampleBuffer : NULL;
}

- (OSStatus)appendUpstreamLengthPrefixedNALUsFromData:(unsigned char *)data
                                               length:(int)length
                                            dataBlock:(CMBlockBufferRef)dataBlock
                                           frameBlock:(CMBlockBufferRef)frameBlock {
    int lastOffset = -1;
    for (int index = 0; index < length - NALU_START_PREFIX_SIZE; index++) {
        if (data[index] == 0 && data[index + 1] == 0 && data[index + 2] == 1) {
            if (lastOffset != -1) {
                OSStatus status = [self appendUpstreamAnnexBBufferForRange:frameBlock
                                                                  dataBlock:dataBlock
                                                                     offset:lastOffset
                                                                     length:index - lastOffset];
                if (status != noErr) {
                    return status;
                }
            }
            lastOffset = index;
        }
    }

    if (lastOffset != -1) {
        OSStatus status = [self appendUpstreamAnnexBBufferForRange:frameBlock
                                                          dataBlock:dataBlock
                                                             offset:lastOffset
                                                             length:length - lastOffset];
        if (status != noErr) {
            return status;
        }
    }
    return CMBlockBufferGetDataLength(frameBlock) > 0 ? noErr : kCMBlockBufferBadLengthParameterErr;
}

- (OSStatus)appendUpstreamAnnexBBufferForRange:(CMBlockBufferRef)frameBlock
                                     dataBlock:(CMBlockBufferRef)dataBlock
                                        offset:(int)offset
                                        length:(int)nalLength {
    if (nalLength <= NALU_START_PREFIX_SIZE) {
        return noErr;
    }

    size_t prefixOffset = CMBlockBufferGetDataLength(frameBlock);
    OSStatus status = CMBlockBufferAppendMemoryBlock(
        frameBlock,
        NULL,
        NAL_LENGTH_PREFIX_SIZE,
        kCFAllocatorDefault,
        NULL,
        0,
        NAL_LENGTH_PREFIX_SIZE,
        0
    );
    if (status != noErr) {
        return status;
    }

    const int dataLength = nalLength - NALU_START_PREFIX_SIZE;
    uint8_t lengthBytes[] = {
        (uint8_t)(dataLength >> 24),
        (uint8_t)(dataLength >> 16),
        (uint8_t)(dataLength >> 8),
        (uint8_t)dataLength
    };
    status = CMBlockBufferReplaceDataBytes(lengthBytes, frameBlock, prefixOffset, NAL_LENGTH_PREFIX_SIZE);
    if (status != noErr) {
        return status;
    }

    return CMBlockBufferAppendBufferReference(
        frameBlock,
        dataBlock,
        (size_t)(offset + NALU_START_PREFIX_SIZE),
        (size_t)dataLength,
        0
    );
}

- (int)nextStartCodeOffsetInData:(const unsigned char *)data length:(int)length offset:(int)offset {
    for (int index = offset; index + 3 < length; index++) {
        if ([self startCodeLengthForData:data length:length atOffset:index] > 0) {
            return index;
        }
    }
    return -1;
}

- (int)nextStartCodeLengthInData:(const unsigned char *)data length:(int)length offset:(int)offset {
    int startCodeOffset = [self nextStartCodeOffsetInData:data length:length offset:offset];
    if (startCodeOffset < 0) {
        return 0;
    }
    return [self startCodeLengthForData:data length:length atOffset:startCodeOffset];
}

- (int)startCodeLengthForData:(const unsigned char *)data length:(int)length atOffset:(int)offset {
    if (offset + 3 <= length && data[offset] == 0 && data[offset + 1] == 0 && data[offset + 2] == 1) {
        return 3;
    }
    if (offset + 4 <= length && data[offset] == 0 && data[offset + 1] == 0 && data[offset + 2] == 0 && data[offset + 3] == 1) {
        return 4;
    }
    return 0;
}

@end
