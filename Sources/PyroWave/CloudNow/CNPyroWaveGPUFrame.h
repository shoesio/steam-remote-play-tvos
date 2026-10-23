#import <Foundation/Foundation.h>
@import Metal;

NS_ASSUME_NONNULL_BEGIN

@interface CNPyroWaveGPUFrame : NSObject

@property (nonatomic, readonly) id<MTLTexture> lumaTexture;
@property (nonatomic, readonly) id<MTLTexture> cbTexture;
@property (nonatomic, readonly) id<MTLTexture> crTexture;
@property (nonatomic, readonly) id<MTLCommandQueue> commandQueue;
@property (nonatomic, readonly) uint64_t sequenceNumber;
@property (nonatomic, readonly) CFTimeInterval decodeSubmittedTime;

- (void)markPresentationCompleteAtTime:(CFTimeInterval)completionTime;

@end

NS_ASSUME_NONNULL_END
