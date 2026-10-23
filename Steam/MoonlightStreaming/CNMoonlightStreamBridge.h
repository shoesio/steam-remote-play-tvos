#import <Foundation/Foundation.h>
#import "CNMoonlightVideoView.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CNMoonlightStreamState) {
    CNMoonlightStreamStateStageStarting = 0,
    CNMoonlightStreamStateStageComplete = 1,
    CNMoonlightStreamStateStageFailed = 2,
    CNMoonlightStreamStateStarted = 3,
    CNMoonlightStreamStateTerminated = 4,
    CNMoonlightStreamStateLog = 5,
    CNMoonlightStreamStateFinished = 6,
};

typedef void (^CNMoonlightStreamProgressHandler)(CNMoonlightStreamState state, NSString *message, NSInteger code);
typedef void (^CNMoonlightMotionEventStateHandler)(NSInteger controllerNumber,
                                                   NSInteger motionType,
                                                   NSInteger reportRateHz);

typedef NS_ENUM(NSInteger, CNMoonlightPreferredVideoCodec) {
    CNMoonlightPreferredVideoCodecAutomatic = 0,
    CNMoonlightPreferredVideoCodecH264 = 1,
    CNMoonlightPreferredVideoCodecPyroWaveExperimental = 2,
};

@interface CNMoonlightStreamBridge : NSObject

+ (NSString *)launchQueryParameters;

@property (nonatomic, copy, nullable) CNMoonlightMotionEventStateHandler motionEventStateHandler;

- (void)startWithHostAddress:(NSString *)hostAddress
                  appVersion:(NSString *)appVersion
              rtspSessionUrl:(nullable NSString *)rtspSessionUrl
       serverCodecModeSupport:(NSInteger)serverCodecModeSupport
                        width:(NSInteger)width
                       height:(NSInteger)height
                          fps:(NSInteger)fps
                    bitrateKbps:(NSInteger)bitrateKbps
                       riKeyHex:(NSString *)riKeyHex
                        riKeyId:(NSInteger)riKeyId
                 useFramePacing:(BOOL)useFramePacing
           adaptiveBitrateEnabled:(BOOL)adaptiveBitrateEnabled
             preferredVideoCodec:(CNMoonlightPreferredVideoCodec)preferredVideoCodec
                      videoView:(nullable CNMoonlightVideoView *)videoView
                       progress:(CNMoonlightStreamProgressHandler)progress;

- (void)stop;

- (NSInteger)sendControllerArrivalWithIndex:(NSInteger)index
                          activeGamepadMask:(NSInteger)activeGamepadMask
                                       type:(NSInteger)type
                       supportedButtonFlags:(NSInteger)supportedButtonFlags
                               capabilities:(NSInteger)capabilities;

- (NSInteger)sendControllerStateWithIndex:(NSInteger)index
                        activeGamepadMask:(NSInteger)activeGamepadMask
                              buttonFlags:(NSInteger)buttonFlags
                              leftTrigger:(NSInteger)leftTrigger
                             rightTrigger:(NSInteger)rightTrigger
                               leftStickX:(NSInteger)leftStickX
                               leftStickY:(NSInteger)leftStickY
                              rightStickX:(NSInteger)rightStickX
                              rightStickY:(NSInteger)rightStickY;

- (NSInteger)sendControllerDisconnectWithIndex:(NSInteger)index
                             activeGamepadMask:(NSInteger)activeGamepadMask;

- (NSInteger)sendMouseMoveWithDeltaX:(NSInteger)deltaX
                               deltaY:(NSInteger)deltaY NS_SWIFT_NAME(sendMouseMove(deltaX:deltaY:));

- (NSInteger)sendMouseButtonWithDown:(BOOL)down
                               button:(NSInteger)button NS_SWIFT_NAME(sendMouseButton(down:button:));

- (NSInteger)sendSteamQuickAccessShortcut;

- (NSInteger)sendControllerMotionWithIndex:(NSInteger)index
                                motionType:(NSInteger)motionType
                                          x:(float)x
                                          y:(float)y
                                          z:(float)z;

@end

NS_ASSUME_NONNULL_END
