#import <Foundation/Foundation.h>
@import CoreMedia;

#include <Limelight.h>

@class CNPyroWaveGPUFrame;

NS_ASSUME_NONNULL_BEGIN

@interface CNMoonlightPyroWaveDecoder : NSObject

@property (nonatomic, copy, readonly) NSString *statusMessage;
@property (nonatomic, assign, readonly, getter=isAvailable) BOOL available;
@property (nonatomic, assign, readonly, getter=isGPUPathAvailable) BOOL GPUPathAvailable;

- (instancetype)initWithWidth:(int)width height:(int)height;
- (void)submitDecodeUnit:(PDECODE_UNIT)decodeUnit
               completion:(void (^)(CMSampleBufferRef _Nullable sampleBuffer, NSString *_Nullable error))completion;
- (void)submitDecodeUnit:(PDECODE_UNIT)decodeUnit
      GPUFrameCompletion:(void (^)(CNPyroWaveGPUFrame *_Nullable GPUFrame,
                                   CMSampleBufferRef _Nullable fallbackSampleBuffer,
                                   NSString *_Nullable error))completion;
/// Transport-neutral entry point used by Punktfunk. The access unit may be a dense
/// PyroWave packet stream or Punktfunk's fixed-window loss-recovery envelope.
- (void)submitPunktfunkAccessUnit:(NSData *)accessUnit
                    chunkAligned:(BOOL)chunkAligned
                       windowSize:(NSUInteger)windowSize
                       frameIndex:(uint32_t)frameIndex
                            ptsNs:(uint64_t)ptsNs
               GPUFrameCompletion:(void (^)(CNPyroWaveGPUFrame *_Nullable GPUFrame,
                                             CMSampleBufferRef _Nullable fallbackSampleBuffer,
                                             NSString *_Nullable error))completion;
- (nullable CMSampleBufferRef)copySampleBufferForDecodeUnit:(PDECODE_UNIT)decodeUnit
                                                      error:(NSString *_Nullable *_Nullable)error CF_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END
