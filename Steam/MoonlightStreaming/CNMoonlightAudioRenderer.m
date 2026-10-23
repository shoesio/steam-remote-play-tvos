#import "CNMoonlightAudioRenderer.h"

@import AVFoundation;

#include "opus/opus_multistream.h"

@interface CNMoonlightAudioRenderer ()
@property (nonatomic, strong, nullable) AVAudioEngine *engine;
@property (nonatomic, strong, nullable) AVAudioPlayerNode *playerNode;
@property (nonatomic, strong, nullable) AVAudioFormat *format;
@property (nonatomic, assign) OpusMSDecoder *decoder;
@property (nonatomic, assign) OPUS_MULTISTREAM_CONFIGURATION audioConfig;
@property (nonatomic, assign) int16_t *decodeBuffer;
@property (nonatomic, assign) size_t decodeBufferBytes;
@property (nonatomic, assign) NSInteger queuedBuffers;
@property (nonatomic, assign) NSInteger droppedBuffers;
@property (nonatomic, assign) NSInteger peakQueuedBuffers;
@property (nonatomic, assign) NSInteger underrunCount;
@property (nonatomic, assign) BOOL playbackRequested;
@property (nonatomic, assign) BOOL playbackStarted;
@end

@implementation CNMoonlightAudioRenderer

static const NSInteger CNMoonlightMaximumQueuedAudioBuffers = 512;
// Solarflare sends 240 samples at 48 kHz (5 ms). Four packets provide a
// deliberately small 20 ms cushion against the player starting on an empty
// queue without materially changing streaming latency.
static const NSInteger CNMoonlightAudioStartupBufferCount = 4;

- (void)dealloc {
    [self cleanup];
}

- (int)setupWithAudioConfiguration:(int)audioConfiguration
                        opusConfig:(const POPUS_MULTISTREAM_CONFIGURATION)opusConfig
                           arFlags:(int)arFlags {
    (void)audioConfiguration;
    (void)arFlags;
    [self cleanup];

    if (!opusConfig || opusConfig->sampleRate <= 0 || opusConfig->channelCount <= 0 || opusConfig->samplesPerFrame <= 0) {
        NSLog(@"[MoonlightAudio] invalid Opus config");
        return -1;
    }

    NSError *sessionError = nil;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    [session setCategory:AVAudioSessionCategoryPlayback
             withOptions:0
                   error:&sessionError];
    if (sessionError) {
        NSLog(@"[MoonlightAudio] failed to set audio session category: %@", sessionError.localizedDescription);
    }
    sessionError = nil;
    [session setMode:AVAudioSessionModeMoviePlayback error:&sessionError];
    if (sessionError) {
        NSLog(@"[MoonlightAudio] failed to set movie playback mode: %@", sessionError.localizedDescription);
    }
    sessionError = nil;
    [session setActive:YES error:&sessionError];
    if (sessionError) {
        NSLog(@"[MoonlightAudio] failed to activate audio session: %@", sessionError.localizedDescription);
    }

    // The active route can support eight channels while its default session
    // format remains stereo. Select the channel count before creating the engine
    // so its mixer inherits the selected hardware format.
    NSInteger requestedOutputChannels = MIN((NSInteger)opusConfig->channelCount,
                                            session.maximumOutputNumberOfChannels);
    sessionError = nil;
    if (requestedOutputChannels > 0 &&
        ![session setPreferredOutputNumberOfChannels:requestedOutputChannels error:&sessionError]) {
        NSLog(@"[MoonlightAudio] output channel request failed: requested=%ld error=%@",
              (long)requestedOutputChannels, sessionError.localizedDescription);
    }
    NSLog(@"[MoonlightAudio] output channel preference: requested=%ld preferred=%ld actual=%ld maximum=%ld",
          (long)requestedOutputChannels, (long)session.preferredOutputNumberOfChannels,
          (long)session.outputNumberOfChannels, (long)session.maximumOutputNumberOfChannels);

    self.audioConfig = *opusConfig;
    AudioChannelLayoutTag layoutTag = kAudioChannelLayoutTag_Stereo;
    if (opusConfig->channelCount == 8) {
        // Moonlight decodes FL FR C LFE RL RR SL SR (WAVE order).
        // AudioUnit_7_1 instead places the side pair before the rear pair.
        layoutTag = kAudioChannelLayoutTag_WAVE_7_1;
    } else if (opusConfig->channelCount == 6) {
        layoutTag = kAudioChannelLayoutTag_AudioUnit_5_1;
    }
    AVAudioChannelLayout *channelLayout = [[AVAudioChannelLayout alloc] initWithLayoutTag:layoutTag];
    self.format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                   sampleRate:opusConfig->sampleRate
                                                  interleaved:YES
                                                channelLayout:channelLayout];
    if (!self.format) {
        NSLog(@"[MoonlightAudio] failed to create PCM format");
        [self cleanup];
        return -1;
    }

    self.decodeBufferBytes = (size_t)opusConfig->samplesPerFrame * (size_t)opusConfig->channelCount * sizeof(int16_t);
    self.decodeBuffer = malloc(self.decodeBufferBytes);
    if (!self.decodeBuffer) {
        NSLog(@"[MoonlightAudio] failed to allocate decode buffer");
        [self cleanup];
        return -1;
    }

    int opusError = OPUS_OK;
    self.decoder = opus_multistream_decoder_create(opusConfig->sampleRate,
                                                   opusConfig->channelCount,
                                                   opusConfig->streams,
                                                   opusConfig->coupledStreams,
                                                   opusConfig->mapping,
                                                   &opusError);
    if (!self.decoder || opusError != OPUS_OK) {
        NSLog(@"[MoonlightAudio] failed to create Opus decoder: %d", opusError);
        [self cleanup];
        return -1;
    }

    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioPlayerNode *playerNode = [[AVAudioPlayerNode alloc] init];
    [engine attachNode:playerNode];
    [engine connect:playerNode to:engine.mainMixerNode format:self.format];
    if (session.outputNumberOfChannels == opusConfig->channelCount) {
        // AVAudioEngine's implicit mixer connection can remain stereo even
        // after the session accepts eight channels. Preserve the decoded layout.
        AVAudioChannelLayout *outputLayout = opusConfig->channelCount == 8
            ? [[AVAudioChannelLayout alloc] initWithLayoutTag:kAudioChannelLayoutTag_AudioUnit_7_1]
            : channelLayout;
        AVAudioFormat *outputFormat = [[AVAudioFormat alloc]
            initWithCommonFormat:AVAudioPCMFormatFloat32
            sampleRate:session.sampleRate
            interleaved:NO
            channelLayout:outputLayout];
        [engine connect:engine.mainMixerNode to:engine.outputNode format:outputFormat];
        if (opusConfig->channelCount == 8) {
            NSLog(@"[MoonlightAudio] 7.1 mapping: decoded FL FR C LFE RL RR SL SR -> output FL FR C LFE SL SR RL RR");
        }
    }
    [engine prepare];

    NSError *engineError = nil;
    if (![engine startAndReturnError:&engineError]) {
        NSLog(@"[MoonlightAudio] failed to start audio engine: %@", engineError.localizedDescription);
        [self cleanup];
        return -1;
    }

    self.engine = engine;
    self.playerNode = playerNode;
    self.queuedBuffers = 0;
    self.droppedBuffers = 0;
    self.peakQueuedBuffers = 0;
    self.underrunCount = 0;
    self.playbackRequested = NO;
    self.playbackStarted = NO;
    NSLog(@"[MoonlightAudio] ready: %d Hz, %d channels, %d samples/frame",
          opusConfig->sampleRate,
          opusConfig->channelCount,
          opusConfig->samplesPerFrame);
    NSMutableArray<NSString *> *routeDescriptions = [NSMutableArray array];
    for (AVAudioSessionPortDescription *output in session.currentRoute.outputs) {
        [routeDescriptions addObject:[NSString stringWithFormat:@"%@/%@ (%lu channels)",
                                      output.portName,
                                      output.portType,
                                      (unsigned long)output.channels.count]];
    }
    AVAudioFormat *mixerFormat = [engine.mainMixerNode outputFormatForBus:0];
    NSLog(@"[MoonlightAudio] output route: %@; session=%ld channels, maximum=%ld; mixer=%u channels at %.0f Hz",
          [routeDescriptions componentsJoinedByString:@", "],
          (long)session.outputNumberOfChannels,
          (long)session.maximumOutputNumberOfChannels,
          mixerFormat.channelCount,
          mixerFormat.sampleRate);
    return 0;
}

- (void)start {
    self.playbackRequested = YES;
    NSLog(@"[MoonlightAudio] stream requested; buffering %ld packets before playback",
          (long)CNMoonlightAudioStartupBufferCount);
}

- (void)stop {
    [self.playerNode stop];
    self.playbackRequested = NO;
    self.playbackStarted = NO;
    @synchronized (self) {
        self.queuedBuffers = 0;
    }
    NSLog(@"[MoonlightAudio] stream stopped");
}

- (void)cleanup {
    [self.playerNode stop];
    [self.engine stop];
    self.playerNode = nil;
    self.engine = nil;
    self.format = nil;
    if (self.decoder) {
        opus_multistream_decoder_destroy(self.decoder);
        self.decoder = NULL;
    }
    if (self.decodeBuffer) {
        free(self.decodeBuffer);
        self.decodeBuffer = NULL;
    }
    self.decodeBufferBytes = 0;
    self.playbackRequested = NO;
    self.playbackStarted = NO;
    @synchronized (self) {
        self.queuedBuffers = 0;
    }
}

- (void)decodeAndPlaySample:(char *)sampleData length:(int)sampleLength {
    if (!self.decoder || !self.playerNode || !self.format || !self.decodeBuffer) {
        return;
    }

    @synchronized (self) {
        if (self.queuedBuffers >= CNMoonlightMaximumQueuedAudioBuffers) {
            self.droppedBuffers += 1;
            if (self.droppedBuffers == 1 || self.droppedBuffers % 100 == 0) {
                NSLog(@"[MoonlightAudio] output queue saturated: queued=%ld dropped=%ld",
                      (long)self.queuedBuffers,
                      (long)self.droppedBuffers);
            }
            return;
        }
    }

    int decodedFrames = opus_multistream_decode(self.decoder,
                                                (const unsigned char *)sampleData,
                                                sampleLength,
                                                self.decodeBuffer,
                                                self.audioConfig.samplesPerFrame,
                                                0);
    if (decodedFrames <= 0) {
        if (decodedFrames < 0) {
            NSLog(@"[MoonlightAudio] Opus decode failed: %d", decodedFrames);
        }
        return;
    }

    AVAudioPCMBuffer *pcmBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.format
                                                                 frameCapacity:(AVAudioFrameCount)decodedFrames];
    if (!pcmBuffer) {
        return;
    }
    pcmBuffer.frameLength = (AVAudioFrameCount)decodedFrames;

    AudioBufferList *audioBufferList = pcmBuffer.mutableAudioBufferList;
    if (audioBufferList->mNumberBuffers < 1 || !audioBufferList->mBuffers[0].mData) {
        return;
    }

    size_t bytesToCopy = (size_t)decodedFrames * (size_t)self.audioConfig.channelCount * sizeof(int16_t);
    memcpy(audioBufferList->mBuffers[0].mData, self.decodeBuffer, bytesToCopy);
    audioBufferList->mBuffers[0].mDataByteSize = (UInt32)bytesToCopy;

    @synchronized (self) {
        self.queuedBuffers += 1;
        self.peakQueuedBuffers = MAX(self.peakQueuedBuffers, self.queuedBuffers);
    }
    __weak typeof(self) weakSelf = self;
    [self.playerNode scheduleBuffer:pcmBuffer completionHandler:^{
        CNMoonlightAudioRenderer *strongSelf = weakSelf;
        if (strongSelf) {
            @synchronized (strongSelf) {
                if (strongSelf.queuedBuffers > 0) {
                    strongSelf.queuedBuffers -= 1;
                }
                if (strongSelf.playbackStarted && strongSelf.queuedBuffers == 0) {
                    strongSelf.underrunCount += 1;
                    if (strongSelf.underrunCount == 1 || strongSelf.underrunCount % 50 == 0) {
                        NSLog(@"[MoonlightAudio] output underrun: count=%ld",
                              (long)strongSelf.underrunCount);
                    }
                }
            }
        }
    }];
    NSInteger queuedBuffers = 0;
    @synchronized (self) {
        queuedBuffers = self.queuedBuffers;
    }
    if (self.playbackRequested && !self.playbackStarted &&
        queuedBuffers >= CNMoonlightAudioStartupBufferCount) {
        [self.playerNode play];
        self.playbackStarted = YES;
        NSLog(@"[MoonlightAudio] playback started with %ld queued packets (%0.1f ms)",
              (long)queuedBuffers,
              1000.0 * self.audioConfig.samplesPerFrame * queuedBuffers / self.audioConfig.sampleRate);
    }
}

@end
