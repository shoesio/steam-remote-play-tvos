#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>

@class CNPyroWaveGPUFrame;

NS_ASSUME_NONNULL_BEGIN

@interface CNMoonlightPyroWaveMetalRenderer : NSObject

@property (nonatomic, readonly) CAMetalLayer *metalLayer;
@property (nonatomic, readonly) NSUInteger renderedFrameCount;
@property (nonatomic, readonly) NSUInteger droppedFrameCount;

- (instancetype)initWithMetalLayer:(CAMetalLayer *)metalLayer;
- (BOOL)renderFrame:(CNPyroWaveGPUFrame *)frame error:(NSString *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
