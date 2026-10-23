#import "CNMoonlightVideoView.h"
#import "CNMoonlightPyroWaveMetalRenderer.h"
#import "CNPyroWaveGPUFrame.h"
#import <GameController/GameController.h>

@interface CNMoonlightVideoView ()
@property (nonatomic, assign) NSInteger videoWidth;
@property (nonatomic, assign) NSInteger videoHeight;
@property (nonatomic, assign) NSInteger decodeUnitCount;
@property (nonatomic, assign) NSInteger idrFrameCount;
@property (nonatomic, assign) NSInteger enqueuedSampleCount;
@property (nonatomic, assign) NSInteger syntheticVideoContentCount;
@property (nonatomic, assign) NSInteger displayLayerResetCount;
@property (nonatomic, assign) NSTimeInterval lastMenuPressTimestamp;
@property (nonatomic, assign) BOOL suppressedMenuPressActive;
@property (nonatomic, assign) BOOL suppressedPlayPausePressActive;
@property (nonatomic, assign) BOOL didTriggerSuppressedControllerExitPress;
@property (nonatomic, assign) BOOL remoteSecondaryPressActive;
@property (nonatomic, assign) BOOL remoteMenuPressActive;
@property (nonatomic, assign) BOOL remoteMenuLongPressTriggered;
@property (nonatomic, copy) NSString *lastRendererEvent;
@property (nonatomic, strong, readwrite) AVSampleBufferDisplayLayer *displayLayer;
@property (nonatomic, strong) CAMetalLayer *pyroWaveMetalLayer;
@property (nonatomic, strong) CNMoonlightPyroWaveMetalRenderer *pyroWaveMetalRenderer;
@end

@implementation CNMoonlightVideoView

static const NSTimeInterval CNDoubledMenuPressInterval = 0.75;
static const NSTimeInterval CNRemoteMenuLongPressInterval = 0.8;
static const float CNGamepadAxisPressedThreshold = 0.25f;

typedef NS_ENUM(NSInteger, CNMoonlightRemoteDirection) {
    CNMoonlightRemoteDirectionNone = 0,
    CNMoonlightRemoteDirectionUp = 1,
    CNMoonlightRemoteDirectionDown = 2,
    CNMoonlightRemoteDirectionLeft = 3,
    CNMoonlightRemoteDirectionRight = 4,
};

static CNMoonlightRemoteDirection CNRemoteDirectionForPress(UIPress *press) {
    switch (press.type) {
        case UIPressTypeUpArrow: return CNMoonlightRemoteDirectionUp;
        case UIPressTypeDownArrow: return CNMoonlightRemoteDirectionDown;
        case UIPressTypeLeftArrow: return CNMoonlightRemoteDirectionLeft;
        case UIPressTypeRightArrow: return CNMoonlightRemoteDirectionRight;
        default: return CNMoonlightRemoteDirectionNone;
    }
}

static NSString *CNDisplayLayerStatusString(AVQueuedSampleBufferRenderingStatus status) {
    switch (status) {
        case AVQueuedSampleBufferRenderingStatusUnknown:
            return @"unknown";
        case AVQueuedSampleBufferRenderingStatusRendering:
            return @"rendering";
        case AVQueuedSampleBufferRenderingStatusFailed:
            return @"failed";
    }
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self configureBaseView];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self configureBaseView];
    }
    return self;
}

- (BOOL)canBecomeFocused {
    return NO;
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) {
        [self setNeedsLayout];
        [self layoutIfNeeded];
        if (self.suppressesSystemPresses) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self becomeFirstResponder];
            });
        }
    }
}

- (void)setSuppressesSystemPresses:(BOOL)suppressesSystemPresses {
    _suppressesSystemPresses = suppressesSystemPresses;
    if (suppressesSystemPresses && self.window) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self becomeFirstResponder];
        });
    }
}

- (void)safeAreaInsetsDidChange {
    [super safeAreaInsetsDidChange];
    [self setNeedsLayout];
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    BOOL handled = NO;
    for (UIPress *press in presses) {
        if (press.type == UIPressTypeSelect
            && press.key == nil
            && self.remoteSelectPressHandler) {
            self.remoteSelectPressHandler(YES);
            handled = YES;
            continue;
        }

        if (press.type == UIPressTypePlayPause
            && self.remoteBackPressHandler) {
            // Claim Play/Pause before controller-system-gesture suppression so
            // the remote remains usable while a real controller is connected.
            self.remoteSecondaryPressActive = YES;
            self.remoteBackPressHandler(YES);
            handled = YES;
            continue;
        }

        CNMoonlightRemoteDirection remoteDirection = CNRemoteDirectionForPress(press);
        if (remoteDirection != CNMoonlightRemoteDirectionNone
            && press.key == nil
            && self.remoteDirectionPressHandler) {
            self.remoteDirectionPressHandler(remoteDirection, YES);
            handled = YES;
            continue;
        }

        if (press.type == UIPressTypeMenu
            && self.remoteMenuPressHandler
            && ![self hasActiveExtendedGamepadInput]) {
            // tvOS reports the Siri Remote's physical Back button as Menu.
            // Defer its Steam-button pulse until release so a hold can remain the
            // intentional app-exit gesture. Checking live extended-gamepad
            // input prevents a controller Menu/Start press being stolen here.
            self.remoteMenuPressActive = YES;
            self.remoteMenuLongPressTriggered = NO;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(CNRemoteMenuLongPressInterval * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (self.remoteMenuPressActive && !self.remoteMenuLongPressTriggered) {
                    self.remoteMenuLongPressTriggered = YES;
                    if (self.menuPressHandler) {
                        self.menuPressHandler();
                    }
                }
            });
            handled = YES;
            continue;
        }

        if (self.suppressesSystemPresses
            && [self hasConnectedExtendedGamepad]
            && [self shouldSuppressControllerSystemPress:press]) {
            // Controller input is forwarded to the host through GameController
            // polling. Only consume controller-originated system/exit presses
            // here; ordinary gameplay presses must remain available to tvOS and
            // Moonlight's input path.
            [self recordSuppressedSystemPressBegan:press];
            handled = YES;
            continue;
        }

        if (press.type == UIPressTypeMenu) {
            if (![self hasConnectedExtendedGamepad] && self.remoteMenuPressHandler) {
                self.remoteMenuPressHandler(YES);
                handled = YES;
                continue;
            }
            NSTimeInterval timestamp = press.timestamp;
            BOOL isDoublePress = self.lastMenuPressTimestamp > 0
                && timestamp - self.lastMenuPressTimestamp <= CNDoubledMenuPressInterval;
            self.lastMenuPressTimestamp = timestamp;

            // A surprising number of tvOS controllers can surface face/back
            // buttons as UIKit Menu presses. Always consume the press so it
            // never bubbles into a stream dismissal, and only treat it as an
            // intentional remote exit when it is a double Menu press from a
            // non-gamepad source. This mirrors Moonlight's "single Menu does
            // nothing, double Menu exits" behavior without reintroducing the
            // GCEventViewController wrapper that has caused launch stalls.
            if (isDoublePress && ![self hasConnectedExtendedGamepad] && self.menuPressHandler) {
                self.menuPressHandler();
            }
            handled = YES;
        } else if (press.type == UIPressTypePlayPause) {
            // A controller-synthesized Play/Pause reaches this path only when
            // it wasn't claimed above as the Siri Remote's Steam Back button.
            handled = YES;
        }
    }
    if (!handled) {
        [super pressesBegan:presses withEvent:event];
    }
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    BOOL handled = NO;
    for (UIPress *press in presses) {
        if (press.type == UIPressTypeSelect
            && press.key == nil
            && self.remoteSelectPressHandler) {
            self.remoteSelectPressHandler(NO);
            handled = YES;
            continue;
        }

        if (press.type == UIPressTypePlayPause && self.remoteSecondaryPressActive) {
            self.remoteSecondaryPressActive = NO;
            if (self.remoteBackPressHandler) {
                self.remoteBackPressHandler(NO);
            }
            handled = YES;
            continue;
        }

        CNMoonlightRemoteDirection remoteDirection = CNRemoteDirectionForPress(press);
        if (remoteDirection != CNMoonlightRemoteDirectionNone
            && press.key == nil
            && self.remoteDirectionPressHandler) {
            self.remoteDirectionPressHandler(remoteDirection, NO);
            handled = YES;
            continue;
        }

        if (press.type == UIPressTypeMenu && self.remoteMenuPressActive) {
            self.remoteMenuPressActive = NO;
            if (!self.remoteMenuLongPressTriggered && self.remoteMenuPressHandler) {
                self.remoteMenuPressHandler(YES);
                self.remoteMenuPressHandler(NO);
            }
            self.remoteMenuLongPressTriggered = NO;
            handled = YES;
            continue;
        }

        if (self.suppressesSystemPresses
            && [self hasConnectedExtendedGamepad]
            && [self shouldSuppressControllerSystemPress:press]) {
            [self recordSuppressedSystemPressEnded:press];
            handled = YES;
            continue;
        }

        if (press.type == UIPressTypeMenu
            && ![self hasConnectedExtendedGamepad]
            && self.remoteMenuPressHandler) {
            self.remoteMenuPressHandler(NO);
            handled = YES;
            continue;
        }

        if (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause) {
            handled = YES;
        }
    }
    if (!handled) {
        [super pressesEnded:presses withEvent:event];
    }
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self pressesEnded:presses withEvent:event];
}

- (void)recordSuppressedSystemPressBegan:(UIPress *)press {
    switch (press.type) {
        case UIPressTypeMenu:
            self.suppressedMenuPressActive = YES;
            break;
        case UIPressTypePlayPause:
            self.suppressedPlayPausePressActive = YES;
            break;
        default:
            break;
    }

    BOOL hasExitChord = self.suppressedMenuPressActive && self.suppressedPlayPausePressActive;
    if (hasExitChord && !self.didTriggerSuppressedControllerExitPress) {
        self.didTriggerSuppressedControllerExitPress = YES;
        if (self.controllerExitPressHandler) {
            self.controllerExitPressHandler();
        }
    }
}

- (void)recordSuppressedSystemPressEnded:(UIPress *)press {
    switch (press.type) {
        case UIPressTypeMenu:
            self.suppressedMenuPressActive = NO;
            break;
        case UIPressTypePlayPause:
            self.suppressedPlayPausePressActive = NO;
            break;
        default:
            break;
    }

    if (!self.suppressedMenuPressActive
        && !self.suppressedPlayPausePressActive) {
        self.didTriggerSuppressedControllerExitPress = NO;
    }
}

- (BOOL)shouldSuppressControllerSystemPress:(UIPress *)press {
    return press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause;
}

- (BOOL)hasActiveExtendedGamepadInput {
    for (GCController *controller in GCController.controllers) {
        if (!controller.extendedGamepad) {
            continue;
        }

        for (GCControllerElement *element in controller.physicalInputProfile.allElements) {
            if ([element isKindOfClass:GCControllerButtonInput.class]) {
                GCControllerButtonInput *button = (GCControllerButtonInput *)element;
                if (button.isPressed || button.value > 0.1f) {
                    return YES;
                }
                continue;
            }

            if ([element isKindOfClass:GCControllerDirectionPad.class]) {
                GCControllerDirectionPad *directionPad = (GCControllerDirectionPad *)element;
                if (fabsf(directionPad.xAxis.value) > CNGamepadAxisPressedThreshold
                    || fabsf(directionPad.yAxis.value) > CNGamepadAxisPressedThreshold
                    || directionPad.up.isPressed
                    || directionPad.down.isPressed
                    || directionPad.left.isPressed
                    || directionPad.right.isPressed) {
                    return YES;
                }
            }
        }
    }
    return NO;
}

- (BOOL)hasConnectedExtendedGamepad {
    for (GCController *controller in GCController.controllers) {
        if (controller.extendedGamepad) {
            return YES;
        }
    }
    return NO;
}

- (void)configureBaseView {
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = YES;
    self.layer.masksToBounds = YES;
    self.videoWidth = 16;
    self.videoHeight = 9;
    self.lastRendererEvent = @"Waiting for renderer";
}

- (void)configureDisplayLayer {
    if (self.displayLayer) {
        [self setNeedsLayout];
        return;
    }

    self.lastRendererEvent = @"Display layer configured";

    AVSampleBufferDisplayLayer *displayLayer = [[AVSampleBufferDisplayLayer alloc] init];
    displayLayer.backgroundColor = UIColor.blackColor.CGColor;
    displayLayer.videoGravity = AVLayerVideoGravityResize;
    displayLayer.affineTransform = CGAffineTransformIdentity;
    displayLayer.hidden = YES;

    self.displayLayer = displayLayer;
    [self.layer addSublayer:displayLayer];

    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGSize boundsSize = self.bounds.size;
    if (boundsSize.width <= 0 || boundsSize.height <= 0) {
        return;
    }

    if (!self.displayLayer && !self.pyroWaveMetalLayer) {
        return;
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    CGFloat aspectRatio = (CGFloat)MAX(self.videoWidth, 1) / (CGFloat)MAX(self.videoHeight, 1);
    CGSize videoSize;
    if (boundsSize.width > boundsSize.height * aspectRatio) {
        videoSize = CGSizeMake(boundsSize.height * aspectRatio, boundsSize.height);
    } else {
        videoSize = CGSizeMake(boundsSize.width, boundsSize.width / aspectRatio);
    }

    CGRect videoFrame = CGRectMake((boundsSize.width - videoSize.width) * 0.5,
                                   (boundsSize.height - videoSize.height) * 0.5,
                                   videoSize.width,
                                   videoSize.height);
    if (self.displayLayer) {
        self.displayLayer.position = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
        self.displayLayer.bounds = CGRectMake(0, 0, videoSize.width, videoSize.height);
        self.displayLayer.affineTransform = CGAffineTransformIdentity;
        self.displayLayer.videoGravity = AVLayerVideoGravityResize;
    }
    if (self.pyroWaveMetalLayer) {
        self.pyroWaveMetalLayer.frame = videoFrame;
        CGFloat scale = self.window.screen.nativeScale > 0 ? self.window.screen.nativeScale : UIScreen.mainScreen.nativeScale;
        self.pyroWaveMetalLayer.contentsScale = scale;
        self.pyroWaveMetalLayer.drawableSize = CGSizeMake(MAX(videoSize.width * scale, 1),
                                                          MAX(videoSize.height * scale, 1));
    }
    [CATransaction commit];

}

- (void)prepareForPyroWaveMetalRendering {
    if (!self.pyroWaveMetalLayer) {
        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.backgroundColor = UIColor.blackColor.CGColor;
        layer.opaque = YES;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = YES;
        layer.maximumDrawableCount = 3;
        layer.allowsNextDrawableTimeout = YES;
        layer.device = MTLCreateSystemDefaultDevice();
        self.pyroWaveMetalLayer = layer;
        self.pyroWaveMetalRenderer = [[CNMoonlightPyroWaveMetalRenderer alloc] initWithMetalLayer:layer];
        [self.layer addSublayer:layer];
    }
    [self.displayLayer flushAndRemoveImage];
    self.displayLayer.hidden = YES;
    self.pyroWaveMetalLayer.hidden = NO;
    self.lastRendererEvent = @"PyroWave Metal renderer ready";
    [self setNeedsLayout];
}

- (BOOL)displayPyroWaveGPUFrame:(CNPyroWaveGPUFrame *)frame error:(NSString **)error {
    // Called from the dedicated presentation queue. Layer creation and layout
    // stay on the main thread in prepareForPyroWaveMetalRendering.
    if (!self.pyroWaveMetalRenderer) {
        [frame markPresentationCompleteAtTime:CACurrentMediaTime()];
        if (error) *error = @"PyroWave Metal surface is not ready";
        return NO;
    }
    BOOL rendered = [self.pyroWaveMetalRenderer renderFrame:frame error:error];
    return rendered;
}

- (void)configureVideoWidth:(NSInteger)width height:(NSInteger)height {
    [self configureDisplayLayer];
    self.videoWidth = MAX(width, 1);
    self.videoHeight = MAX(height, 1);
    self.lastRendererEvent = [NSString stringWithFormat:@"Video setup %ldx%ld", (long)self.videoWidth, (long)self.videoHeight];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setNeedsLayout];
    });
}

- (void)resetDisplayLayer {
    [self configureDisplayLayer];
    [self.displayLayer flushAndRemoveImage];
    self.displayLayer.hidden = YES;
    self.pyroWaveMetalLayer.hidden = YES;
    self.syntheticVideoContentCount = 0;
    self.displayLayerResetCount += 1;
    self.lastRendererEvent = @"Display layer reset";
}

- (BOOL)hasVisibleVideoContent {
    BOOL metalVisible = self.pyroWaveMetalLayer && !self.pyroWaveMetalLayer.hidden
        && self.pyroWaveMetalRenderer.renderedFrameCount > 0;
    BOOL sampleVisible = self.displayLayer
        && (self.enqueuedSampleCount > 0 || self.syntheticVideoContentCount > 0)
        && self.displayLayer.status != AVQueuedSampleBufferRenderingStatusFailed;
    return metalVisible || sampleVisible;
}

- (void)recordDecodeUnitWithIDR:(BOOL)isIDR {
    self.decodeUnitCount += 1;
    if (isIDR) {
        self.idrFrameCount += 1;
        self.lastRendererEvent = @"Received video keyframe";
    } else if (self.decodeUnitCount == 1 || self.decodeUnitCount % 120 == 0) {
        self.lastRendererEvent = [NSString stringWithFormat:@"Received video frame %ld", (long)self.decodeUnitCount];
    }
}

- (void)recordSampleBufferEnqueued {
    self.enqueuedSampleCount += 1;
    self.lastRendererEvent = [NSString stringWithFormat:@"Enqueued sample %ld", (long)self.enqueuedSampleCount];
}

- (void)recordSyntheticVideoContent {
    [self configureDisplayLayer];
    self.syntheticVideoContentCount += 1;
    self.displayLayer.hidden = NO;
    self.lastRendererEvent = [NSString stringWithFormat:@"Synthetic video content %ld", (long)self.syntheticVideoContentCount];
}

- (void)recordDisplayLayerResetWithReason:(NSString *)reason {
    self.lastRendererEvent = reason.length > 0 ? reason : @"Display layer reset";
}

- (void)recordRendererEvent:(NSString *)event {
    if (event.length > 0) {
        self.lastRendererEvent = event;
    }
}

- (NSString *)diagnosticsString {
    AVSampleBufferDisplayLayer *displayLayer = self.displayLayer;
    CGRect windowFrame = CGRectZero;
    CGRect screenBounds = CGRectZero;
    CGRect superviewFrame = CGRectZero;
    CGRect superviewBounds = CGRectZero;
    UIEdgeInsets windowSafeArea = UIEdgeInsetsZero;
    CGFloat screenScale = 0;

    if (self.superview) {
        superviewFrame = self.superview.frame;
        superviewBounds = self.superview.bounds;
    }

    if (self.window) {
        windowFrame = self.window.frame;
        windowSafeArea = self.window.safeAreaInsets;
        screenBounds = self.window.screen.bounds;
        screenScale = self.window.screen.scale;
    } else if (UIScreen.mainScreen) {
        screenBounds = UIScreen.mainScreen.bounds;
        screenScale = UIScreen.mainScreen.scale;
    }

    NSString *layerStatus = displayLayer ? CNDisplayLayerStatusString(displayLayer.status) : @"not-created";
    NSString *layerError = displayLayer.error.localizedDescription ?: @"none";
    NSString *layerGravity = displayLayer.videoGravity ?: @"none";

    return [NSString stringWithFormat:
        @"view frame=%@ bounds=%@ safe=%@\n"
         "super frame=%@ bounds=%@\n"
         "layer frame=%@ bounds=%@ position=%@ hidden=%@ status=%@ error=%@ gravity=%@\n"
         "video=%ldx%ld decode=%ld idr=%ld enqueued=%ld synthetic=%ld resets=%ld visible=%@\n"
         "last=%@ window=%@ winSafe=%@ screen=%@ scale=%.1f",
        NSStringFromCGRect(self.frame),
        NSStringFromCGRect(self.bounds),
        NSStringFromUIEdgeInsets(self.safeAreaInsets),
        NSStringFromCGRect(superviewFrame),
        NSStringFromCGRect(superviewBounds),
        NSStringFromCGRect(displayLayer ? displayLayer.frame : CGRectZero),
        NSStringFromCGRect(displayLayer ? displayLayer.bounds : CGRectZero),
        NSStringFromCGPoint(displayLayer ? displayLayer.position : CGPointZero),
        (!displayLayer || displayLayer.hidden) ? @"yes" : @"no",
        layerStatus,
        layerError,
        layerGravity,
        (long)self.videoWidth,
        (long)self.videoHeight,
        (long)self.decodeUnitCount,
        (long)self.idrFrameCount,
        (long)self.enqueuedSampleCount,
        (long)self.syntheticVideoContentCount,
        (long)self.displayLayerResetCount,
        self.hasVisibleVideoContent ? @"yes" : @"no",
        self.lastRendererEvent ?: @"none",
        NSStringFromCGRect(windowFrame),
        NSStringFromUIEdgeInsets(windowSafeArea),
        NSStringFromCGRect(screenBounds),
        screenScale
    ];
}

- (NSDictionary<NSString *, id> *)diagnosticsSnapshot {
    AVSampleBufferDisplayLayer *displayLayer = self.displayLayer;
    CGRect windowFrame = CGRectZero;
    CGRect screenBounds = CGRectZero;
    CGRect superviewFrame = CGRectZero;
    CGRect superviewBounds = CGRectZero;
    UIEdgeInsets windowSafeArea = UIEdgeInsetsZero;
    CGFloat screenScale = 0;

    if (self.superview) {
        superviewFrame = self.superview.frame;
        superviewBounds = self.superview.bounds;
    }

    if (self.window) {
        windowFrame = self.window.frame;
        windowSafeArea = self.window.safeAreaInsets;
        screenBounds = self.window.screen.bounds;
        screenScale = self.window.screen.scale;
    } else if (UIScreen.mainScreen) {
        screenBounds = UIScreen.mainScreen.bounds;
        screenScale = UIScreen.mainScreen.scale;
    }

    NSString *layerError = displayLayer.error.localizedDescription ?: @"none";
    NSString *layerGravity = displayLayer.videoGravity ?: @"none";

    CGRect layerFrame = displayLayer ? displayLayer.frame : CGRectZero;
    CGRect layerBounds = displayLayer ? displayLayer.bounds : CGRectZero;

    return @{
        @"viewFrameX": @(self.frame.origin.x),
        @"viewFrameY": @(self.frame.origin.y),
        @"viewFrameW": @(self.frame.size.width),
        @"viewFrameH": @(self.frame.size.height),
        @"viewBoundsX": @(self.bounds.origin.x),
        @"viewBoundsY": @(self.bounds.origin.y),
        @"viewBoundsW": @(self.bounds.size.width),
        @"viewBoundsH": @(self.bounds.size.height),
        @"viewSafeTop": @(self.safeAreaInsets.top),
        @"viewSafeLeft": @(self.safeAreaInsets.left),
        @"viewSafeBottom": @(self.safeAreaInsets.bottom),
        @"viewSafeRight": @(self.safeAreaInsets.right),
        @"superFrameX": @(superviewFrame.origin.x),
        @"superFrameY": @(superviewFrame.origin.y),
        @"superFrameW": @(superviewFrame.size.width),
        @"superFrameH": @(superviewFrame.size.height),
        @"superBoundsW": @(superviewBounds.size.width),
        @"superBoundsH": @(superviewBounds.size.height),
        @"layerFrameX": @(layerFrame.origin.x),
        @"layerFrameY": @(layerFrame.origin.y),
        @"layerFrameW": @(layerFrame.size.width),
        @"layerFrameH": @(layerFrame.size.height),
        @"layerBoundsW": @(layerBounds.size.width),
        @"layerBoundsH": @(layerBounds.size.height),
        @"layerPositionX": @(displayLayer ? displayLayer.position.x : 0),
        @"layerPositionY": @(displayLayer ? displayLayer.position.y : 0),
        @"layerHidden": @(!displayLayer || displayLayer.hidden),
        @"layerStatus": displayLayer ? CNDisplayLayerStatusString(displayLayer.status) : @"not-created",
        @"layerError": layerError,
        @"layerGravity": layerGravity,
        @"videoW": @(self.videoWidth),
        @"videoH": @(self.videoHeight),
        @"decode": @(self.decodeUnitCount),
        @"idr": @(self.idrFrameCount),
        @"enqueued": @(self.enqueuedSampleCount),
        @"synthetic": @(self.syntheticVideoContentCount),
        @"resets": @(self.displayLayerResetCount),
        @"visible": @(self.hasVisibleVideoContent),
        @"last": self.lastRendererEvent ?: @"none",
        @"windowFrameX": @(windowFrame.origin.x),
        @"windowFrameY": @(windowFrame.origin.y),
        @"windowFrameW": @(windowFrame.size.width),
        @"windowFrameH": @(windowFrame.size.height),
        @"windowSafeTop": @(windowSafeArea.top),
        @"windowSafeLeft": @(windowSafeArea.left),
        @"windowSafeBottom": @(windowSafeArea.bottom),
        @"windowSafeRight": @(windowSafeArea.right),
        @"screenW": @(screenBounds.size.width),
        @"screenH": @(screenBounds.size.height),
        @"screenScale": @(screenScale)
    };
}

@end
