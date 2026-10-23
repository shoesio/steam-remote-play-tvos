#import <UIKit/UIKit.h>
@import AVFoundation;

@class CNPyroWaveGPUFrame;

NS_ASSUME_NONNULL_BEGIN

typedef void (^CNMoonlightMenuPressHandler)(void);
typedef void (^CNMoonlightControllerExitPressHandler)(void);
typedef void (^CNMoonlightRemoteDirectionPressHandler)(NSInteger direction, BOOL pressed);
typedef void (^CNMoonlightRemoteButtonPressHandler)(BOOL pressed);

@interface CNMoonlightVideoView : UIView

@property (nonatomic, readonly) AVSampleBufferDisplayLayer *displayLayer;
@property (nonatomic, copy, nullable) CNMoonlightMenuPressHandler menuPressHandler;
@property (nonatomic, copy, nullable) CNMoonlightControllerExitPressHandler controllerExitPressHandler;
@property (nonatomic, copy, nullable) CNMoonlightRemoteDirectionPressHandler remoteDirectionPressHandler;
@property (nonatomic, copy, nullable) CNMoonlightRemoteButtonPressHandler remoteSelectPressHandler;
@property (nonatomic, copy, nullable) CNMoonlightRemoteButtonPressHandler remoteBackPressHandler;
@property (nonatomic, copy, nullable) CNMoonlightRemoteButtonPressHandler remoteMenuPressHandler;
@property (nonatomic, assign) BOOL suppressesSystemPresses;
@property (nonatomic, readonly) BOOL hasVisibleVideoContent;

- (void)configureVideoWidth:(NSInteger)width height:(NSInteger)height;
- (void)prepareForPyroWaveMetalRendering;
- (BOOL)displayPyroWaveGPUFrame:(CNPyroWaveGPUFrame *)frame error:(NSString *_Nullable *_Nullable)error;
- (void)resetDisplayLayer;
- (void)recordDecodeUnitWithIDR:(BOOL)isIDR;
- (void)recordSyntheticVideoContent;
- (void)recordSampleBufferEnqueued;
- (void)recordDisplayLayerResetWithReason:(NSString *)reason;
- (void)recordRendererEvent:(NSString *)event;
- (NSString *)diagnosticsString;
- (NSDictionary<NSString *, id> *)diagnosticsSnapshot;

@end

NS_ASSUME_NONNULL_END
