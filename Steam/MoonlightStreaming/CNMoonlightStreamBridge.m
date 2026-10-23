#import "CNMoonlightStreamBridge.h"
#import "CNMoonlightAudioRenderer.h"
#import "CNMoonlightVideoRenderer.h"

#include <arpa/inet.h>
#include <limits.h>
#include <stdarg.h>
#include <string.h>

#include "Limelight.h"

static __weak CNMoonlightStreamBridge *CNMoonlightActiveBridge;
static void CNSetMotionEventState(uint16_t controllerNumber, uint8_t motionType, uint16_t reportRateHz);

@interface CNMoonlightStreamBridge ()
@property (nonatomic, copy, nullable) CNMoonlightStreamProgressHandler progress;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, copy) NSString *hostAddress;
@property (nonatomic, copy) NSString *appVersion;
@property (nonatomic, copy, nullable) NSString *rtspSessionUrl;
@property (nonatomic, copy) NSString *riKeyHex;
@property (nonatomic, assign) NSInteger serverCodecModeSupport;
@property (nonatomic, assign) NSInteger width;
@property (nonatomic, assign) NSInteger height;
@property (nonatomic, assign) NSInteger fps;
@property (nonatomic, assign) NSInteger bitrateKbps;
@property (nonatomic, assign) NSInteger riKeyId;
@property (nonatomic, assign) BOOL useFramePacing;
@property (nonatomic, assign) BOOL adaptiveBitrateEnabled;
@property (nonatomic, assign) CNMoonlightPreferredVideoCodec preferredVideoCodec;
@property (nonatomic, strong, nullable) CNMoonlightAudioRenderer *audioRenderer;
@property (nonatomic, strong, nullable) CNMoonlightVideoRenderer *videoRenderer;
@end

@implementation CNMoonlightStreamBridge

+ (NSString *)launchQueryParameters {
    const char *query = LiGetLaunchUrlQueryParameters();
    return query ? [NSString stringWithUTF8String:query] : @"";
}

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
                     progress:(CNMoonlightStreamProgressHandler)progress {
    if (self.running) {
        return;
    }

    self.running = YES;
    self.hostAddress = hostAddress;
    self.appVersion = appVersion.length > 0 ? appVersion : @"0.0.0";
    self.rtspSessionUrl = rtspSessionUrl;
    self.serverCodecModeSupport = serverCodecModeSupport;
    self.width = width;
    self.height = height;
    self.fps = fps;
    self.bitrateKbps = bitrateKbps;
    self.riKeyHex = riKeyHex;
    self.riKeyId = riKeyId;
    self.useFramePacing = useFramePacing;
    // Pre-adaptive checkpoint behaviour: Auto selects a fixed bitrate before
    // launch and never changes the encoder budget during an active stream.
    self.adaptiveBitrateEnabled = NO;
    self.preferredVideoCodec = preferredVideoCodec;
    self.progress = progress;
    self.audioRenderer = [[CNMoonlightAudioRenderer alloc] init];
    self.videoRenderer = videoView ? [[CNMoonlightVideoRenderer alloc]
                                      initWithVideoView:videoView
                                      useFramePacing:useFramePacing
                                      adaptiveBitrateEnabled:NO
                                      bitrateCeilingKbps:bitrateKbps
                                      targetFPS:fps] : nil;
    CNMoonlightActiveBridge = self;

    if (!videoView) {
        [self emit:CNMoonlightStreamStateLog message:@"Moonlight video renderer disabled: video surface is nil" code:0];
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [weakSelf runConnection];
    });
}

- (void)stop {
    // Failed setup/termination paths do not always deliver Moonlight's video
    // stop callback. Stop the renderer unconditionally so its adaptive timer
    // cannot survive into the next stream attempt.
    [self.videoRenderer stop];
    if (!self.running) {
        return;
    }
    LiInterruptConnection();
    LiStopConnection();
    self.running = NO;
}

- (NSInteger)sendControllerArrivalWithIndex:(NSInteger)index
                          activeGamepadMask:(NSInteger)activeGamepadMask
                                       type:(NSInteger)type
                       supportedButtonFlags:(NSInteger)supportedButtonFlags
                               capabilities:(NSInteger)capabilities {
    if (!self.running) {
        return -999;
    }

    return LiSendControllerArrivalEvent((uint8_t)MAX(0, MIN(index, 15)),
                                        (uint16_t)activeGamepadMask,
                                        (uint8_t)type,
                                        (uint32_t)supportedButtonFlags,
                                        (uint16_t)capabilities);
}

- (NSInteger)sendControllerStateWithIndex:(NSInteger)index
                        activeGamepadMask:(NSInteger)activeGamepadMask
                              buttonFlags:(NSInteger)buttonFlags
                              leftTrigger:(NSInteger)leftTrigger
                             rightTrigger:(NSInteger)rightTrigger
                               leftStickX:(NSInteger)leftStickX
                               leftStickY:(NSInteger)leftStickY
                              rightStickX:(NSInteger)rightStickX
                              rightStickY:(NSInteger)rightStickY {
    if (!self.running) {
        return -999;
    }

    return LiSendMultiControllerEvent((short)MAX(0, MIN(index, 15)),
                                      (short)activeGamepadMask,
                                      (int)buttonFlags,
                                      (unsigned char)MAX(0, MIN(leftTrigger, 255)),
                                      (unsigned char)MAX(0, MIN(rightTrigger, 255)),
                                      (short)leftStickX,
                                      (short)leftStickY,
                                      (short)rightStickX,
                                      (short)rightStickY);
}

- (NSInteger)sendControllerDisconnectWithIndex:(NSInteger)index
                             activeGamepadMask:(NSInteger)activeGamepadMask {
    if (!self.running) {
        return -999;
    }

    return LiSendMultiControllerEvent((short)MAX(0, MIN(index, 15)),
                                      (short)activeGamepadMask,
                                      0,
                                      0,
                                      0,
                                      0,
                                      0,
                                      0,
                                      0);
}

- (NSInteger)sendControllerMotionWithIndex:(NSInteger)index
                                motionType:(NSInteger)motionType
                                          x:(float)x
                                          y:(float)y
                                          z:(float)z {
    if (!self.running) {
        return -999;
    }

    return LiSendControllerMotionEvent((uint8_t)MAX(0, MIN(index, 15)),
                                       (uint8_t)motionType,
                                       x,
                                       y,
                                       z);
}

- (NSInteger)sendMouseMoveWithDeltaX:(NSInteger)deltaX deltaY:(NSInteger)deltaY {
    if (!self.running) {
        return -999;
    }

    return LiSendMouseMoveEvent((short)MAX(SHRT_MIN, MIN(deltaX, SHRT_MAX)),
                                (short)MAX(SHRT_MIN, MIN(deltaY, SHRT_MAX)));
}

- (NSInteger)sendMouseButtonWithDown:(BOOL)down button:(NSInteger)button {
    if (!self.running) {
        return -999;
    }

    return LiSendMouseButtonEvent(down ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE,
                                  (int)MAX(BUTTON_LEFT, MIN(button, BUTTON_X2)));
}

- (NSInteger)sendSteamQuickAccessShortcut {
    if (!self.running) {
        return -999;
    }

    // Steam Game Mode's Quick Access Menu shortcut is Ctrl+2.
    // Send an explicit left-Control key around the modified number-key events
    // so Linux/Sunshine sees the same chord as a physical keyboard.
    const short leftControl = 0xA2;
    const short numberTwo = 0x32;
    NSInteger result = LiSendKeyboardEvent(leftControl, KEY_ACTION_DOWN, 0);
    if (result == 0) {
        result = LiSendKeyboardEvent(numberTwo, KEY_ACTION_DOWN, MODIFIER_CTRL);
    }
    NSInteger releaseResult = LiSendKeyboardEvent(numberTwo, KEY_ACTION_UP, MODIFIER_CTRL);
    NSInteger controlReleaseResult = LiSendKeyboardEvent(leftControl, KEY_ACTION_UP, 0);
    if (result != 0) {
        return result;
    }
    if (releaseResult != 0) {
        return releaseResult;
    }
    return controlReleaseResult;
}

- (void)runConnection {
    char host[256] = {0};
    char appVersion[64] = {0};
    char rtspSessionUrl[256] = {0};

    strncpy(host, self.hostAddress.UTF8String, sizeof(host) - 1);
    strncpy(appVersion, self.appVersion.UTF8String, sizeof(appVersion) - 1);
    if (self.rtspSessionUrl.length > 0) {
        strncpy(rtspSessionUrl, self.rtspSessionUrl.UTF8String, sizeof(rtspSessionUrl) - 1);
    }

    SERVER_INFORMATION serverInfo;
    LiInitializeServerInformation(&serverInfo);
    serverInfo.address = host;
    serverInfo.serverInfoAppVersion = appVersion;
    serverInfo.serverCodecModeSupport = self.serverCodecModeSupport > 0 ? (int)self.serverCodecModeSupport : SCM_H264;
    if (rtspSessionUrl[0] != '\0') {
        serverInfo.rtspSessionUrl = rtspSessionUrl;
    }

    [self emit:CNMoonlightStreamStateLog
       message:[NSString stringWithFormat:@"Solarflare server codec capabilities 0x%08x; PyroWave bit 0x%08x",
                                          serverInfo.serverCodecModeSupport,
                                          SCM_PYROWAVE]
          code:0];
    if (self.preferredVideoCodec == CNMoonlightPreferredVideoCodecPyroWaveExperimental &&
        (serverInfo.serverCodecModeSupport & SCM_PYROWAVE) == 0) {
        [self emit:CNMoonlightStreamStateStageFailed
           message:@"Solarflare did not advertise SDR PyroWave support; refusing codec fallback"
              code:-2001];
        self.running = NO;
        return;
    }

    STREAM_CONFIGURATION streamConfig;
    LiInitializeStreamConfiguration(&streamConfig);
    streamConfig.width = (int)MAX(self.width, 1280);
    streamConfig.height = (int)MAX(self.height, 720);
    streamConfig.fps = (int)MAX(self.fps, 30);
    streamConfig.bitrate = (int)MAX(self.bitrateKbps, 10 * 1000);
    streamConfig.packetSize = 1392;
    streamConfig.streamingRemotely = STREAM_CFG_AUTO;
    streamConfig.audioConfiguration = AUDIO_CONFIGURATION_71_SURROUND;
    streamConfig.supportedVideoFormats = [self supportedVideoFormatsForPreferredCodec:self.preferredVideoCodec];
    [self emit:CNMoonlightStreamStateLog
       message:[NSString stringWithFormat:@"Moonlight codec preference %ld formats 0x%08x",
                                          (long)self.preferredVideoCodec,
                                          streamConfig.supportedVideoFormats]
          code:0];
    streamConfig.clientRefreshRateX100 = streamConfig.fps * 100;
    streamConfig.colorSpace = COLORSPACE_REC_709;
    streamConfig.colorRange = COLOR_RANGE_LIMITED;
    streamConfig.encryptionFlags = ENCFLG_ALL;
    // First Solarflare validation profile: fixed SDR 4:2:0 with conservative,
    // non-adaptive LAN transport. These flags are optional RTSP attributes;
    // keeping them off makes the first wire test deterministic.
    streamConfig.pyroWaveAdaptiveFec = 0;
    streamConfig.pyroWaveAdaptiveBitrate = 0;

    NSData *riKeyData = [self dataFromHex:self.riKeyHex];
    if (riKeyData.length == sizeof(streamConfig.remoteInputAesKey)) {
        memcpy(streamConfig.remoteInputAesKey, riKeyData.bytes, sizeof(streamConfig.remoteInputAesKey));
    }
    memset(streamConfig.remoteInputAesIv, 0, sizeof(streamConfig.remoteInputAesIv));
    uint32_t networkRiKeyId = htonl((uint32_t)self.riKeyId);
    memcpy(streamConfig.remoteInputAesIv, &networkRiKeyId, sizeof(networkRiKeyId));

    CONNECTION_LISTENER_CALLBACKS connectionCallbacks;
    LiInitializeConnectionCallbacks(&connectionCallbacks);
    connectionCallbacks.stageStarting = CNStageStarting;
    connectionCallbacks.stageComplete = CNStageComplete;
    connectionCallbacks.stageFailed = CNStageFailed;
    connectionCallbacks.connectionStarted = CNConnectionStarted;
    connectionCallbacks.connectionTerminated = CNConnectionTerminated;
    connectionCallbacks.logMessage = CNLogMessage;
    connectionCallbacks.setMotionEventState = CNSetMotionEventState;

    DECODER_RENDERER_CALLBACKS videoCallbacks;
    DECODER_RENDERER_CALLBACKS *videoCallbacksPointer = NULL;
    if (self.videoRenderer) {
        LiInitializeVideoCallbacks(&videoCallbacks);
        videoCallbacks.setup = CNVideoSetup;
        videoCallbacks.start = CNVideoStart;
        videoCallbacks.stop = CNVideoStop;
        videoCallbacks.cleanup = CNVideoCleanup;
        videoCallbacks.submitDecodeUnit = CNVideoSubmitDecodeUnit;
        videoCallbacks.capabilities = CAPABILITY_REFERENCE_FRAME_INVALIDATION_AVC;
        if (self.preferredVideoCodec == CNMoonlightPreferredVideoCodecPyroWaveExperimental) {
            videoCallbacks.capabilities |= CAPABILITY_DIRECT_SUBMIT;
        }
        videoCallbacksPointer = &videoCallbacks;
    }

    AUDIO_RENDERER_CALLBACKS audioCallbacks;
    LiInitializeAudioCallbacks(&audioCallbacks);
    audioCallbacks.init = CNAudioInit;
    audioCallbacks.start = CNAudioStart;
    audioCallbacks.stop = CNAudioStop;
    audioCallbacks.cleanup = CNAudioCleanup;
    audioCallbacks.decodeAndPlaySample = CNAudioDecodeAndPlaySample;
    audioCallbacks.capabilities = CAPABILITY_SUPPORTS_ARBITRARY_AUDIO_DURATION;

    int result = LiStartConnection(&serverInfo, &streamConfig, &connectionCallbacks, videoCallbacksPointer, &audioCallbacks, NULL, 0, NULL, 0);
    if (result == 0) {
        [self emit:CNMoonlightStreamStateFinished message:@"Moonlight startup completed" code:result];
    } else {
        [self emit:CNMoonlightStreamStateFinished message:[NSString stringWithFormat:@"Moonlight startup failed with code %d", result] code:result];
        self.running = NO;
        [self.videoRenderer stop];
    }
}

- (int)supportedVideoFormatsForPreferredCodec:(CNMoonlightPreferredVideoCodec)preferredVideoCodec {
    switch (preferredVideoCodec) {
        case CNMoonlightPreferredVideoCodecPyroWaveExperimental:
            // PyroWave is mandatory in this client. Never silently negotiate
            // H.264/HEVC when Solarflare negotiation is missing or rejected.
            return VIDEO_FORMAT_PYROWAVE;
        case CNMoonlightPreferredVideoCodecAutomatic:
        case CNMoonlightPreferredVideoCodecH264:
        default:
            return VIDEO_FORMAT_H264;
    }
}

- (NSData *)dataFromHex:(NSString *)hex {
    NSMutableData *data = [NSMutableData dataWithCapacity:hex.length / 2];
    for (NSUInteger index = 0; index + 1 < hex.length; index += 2) {
        NSString *byteString = [hex substringWithRange:NSMakeRange(index, 2)];
        unsigned int value = 0;
        [[NSScanner scannerWithString:byteString] scanHexInt:&value];
        uint8_t byte = (uint8_t)value;
        [data appendBytes:&byte length:1];
    }
    return data;
}

- (void)emit:(CNMoonlightStreamState)state message:(NSString *)message code:(NSInteger)code {
    CNMoonlightStreamProgressHandler handler = self.progress;
    if (!handler) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(state, message, code);
    });
}

static void CNEmit(CNMoonlightStreamState state, NSString *message, NSInteger code) {
    [CNMoonlightActiveBridge emit:state message:message code:code];
}

static void CNSetMotionEventState(uint16_t controllerNumber, uint8_t motionType, uint16_t reportRateHz) {
    CNMoonlightStreamBridge *bridge = CNMoonlightActiveBridge;
    CNMoonlightMotionEventStateHandler handler = bridge.motionEventStateHandler;
    if (!handler) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        handler(controllerNumber, motionType, reportRateHz);
    });
}

static NSString *CNStageName(int stage) {
    const char *stageName = LiGetStageName(stage);
    return stageName ? [NSString stringWithUTF8String:stageName] : [NSString stringWithFormat:@"Stage %d", stage];
}

static void CNStageStarting(int stage) {
    CNEmit(CNMoonlightStreamStateStageStarting, [NSString stringWithFormat:@"Starting %@", CNStageName(stage)], stage);
}

static void CNStageComplete(int stage) {
    CNEmit(CNMoonlightStreamStateStageComplete, [NSString stringWithFormat:@"Finished %@", CNStageName(stage)], stage);
}

static void CNStageFailed(int stage, int errorCode) {
    CNEmit(CNMoonlightStreamStateStageFailed, [NSString stringWithFormat:@"%@ failed", CNStageName(stage)], errorCode);
}

static void CNConnectionStarted(void) {
    CNEmit(CNMoonlightStreamStateStarted, @"Moonlight stream connected", 0);
}

static void CNConnectionTerminated(int errorCode) {
    CNMoonlightActiveBridge.running = NO;
    [CNMoonlightActiveBridge.videoRenderer stop];
    CNEmit(CNMoonlightStreamStateTerminated, [NSString stringWithFormat:@"Moonlight stream ended with code %d", errorCode], errorCode);
}

static void CNLogMessage(const char *format, ...) {
    if (!format) {
        return;
    }
    char buffer[512];
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    NSString *message = [NSString stringWithUTF8String:buffer];
    NSString *lowercaseMessage = message.lowercaseString;
    if ([lowercaseMessage containsString:@"audio data"] || [lowercaseMessage containsString:@"audio packet"]) {
        return;
    }
    CNEmit(CNMoonlightStreamStateLog, message, 0);
}

static int CNVideoSetup(int videoFormat, int width, int height, int redrawRate, void *context, int drFlags) {
    CNEmit(CNMoonlightStreamStateLog, [NSString stringWithFormat:@"Video setup format 0x%08x %dx%d @ %d", videoFormat, width, height, redrawRate], 0);
    if (CNMoonlightActiveBridge.preferredVideoCodec == CNMoonlightPreferredVideoCodecPyroWaveExperimental &&
        (videoFormat & VIDEO_FORMAT_MASK_PYROWAVE) == 0) {
        CNEmit(CNMoonlightStreamStateStageFailed,
               @"RTSP did not confirm PyroWave; refusing H.264/HEVC fallback",
               -2002);
        return DR_NEED_IDR;
    }
    CNEmit(CNMoonlightStreamStateLog,
           [NSString stringWithFormat:@"Confirmed Solarflare PyroWave selection format=0x%08x SDR=%d chroma420=%d",
                                      videoFormat,
                                      (videoFormat & VIDEO_FORMAT_MASK_10BIT) == 0,
                                      (videoFormat & VIDEO_FORMAT_MASK_YUV444) == 0],
           0);
    return [CNMoonlightActiveBridge.videoRenderer setupWithVideoFormat:videoFormat width:width height:height redrawRate:redrawRate];
}

static void CNVideoStart(void) {
    CNEmit(CNMoonlightStreamStateLog, @"Video stream started", 0);
    [CNMoonlightActiveBridge.videoRenderer start];
}

static void CNVideoStop(void) {
    CNEmit(CNMoonlightStreamStateLog, @"Video stream stopped", 0);
    [CNMoonlightActiveBridge.videoRenderer stop];
}

static void CNVideoCleanup(void) {
    CNEmit(CNMoonlightStreamStateLog, @"Video renderer cleaned up", 0);
    [CNMoonlightActiveBridge.videoRenderer cleanup];
}

static int CNVideoSubmitDecodeUnit(PDECODE_UNIT decodeUnit) {
    return [CNMoonlightActiveBridge.videoRenderer submitDecodeUnit:decodeUnit];
}

static int CNAudioInit(int audioConfiguration, const POPUS_MULTISTREAM_CONFIGURATION opusConfig, void *context, int arFlags) {
    (void)context;
    CNEmit(CNMoonlightStreamStateLog, @"Audio renderer initializing", 0);
    return [CNMoonlightActiveBridge.audioRenderer setupWithAudioConfiguration:audioConfiguration opusConfig:opusConfig arFlags:arFlags];
}

static void CNAudioStart(void) {
    CNEmit(CNMoonlightStreamStateLog, @"Audio stream started", 0);
    [CNMoonlightActiveBridge.audioRenderer start];
}

static void CNAudioStop(void) {
    CNEmit(CNMoonlightStreamStateLog, @"Audio stream stopped", 0);
    [CNMoonlightActiveBridge.audioRenderer stop];
}

static void CNAudioCleanup(void) {
    CNEmit(CNMoonlightStreamStateLog, @"Audio renderer cleaned up", 0);
    [CNMoonlightActiveBridge.audioRenderer cleanup];
}

static void CNAudioDecodeAndPlaySample(char *sampleData, int sampleLength) {
    [CNMoonlightActiveBridge.audioRenderer decodeAndPlaySample:sampleData length:sampleLength];
}

@end
