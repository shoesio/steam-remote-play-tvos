#import "SteamPyroWaveBridge.h"
#import "CNMoonlightPyroWaveDecoder.h"
#include "Limelight.h"

@interface SteamPyroWaveBridge ()
@property(nonatomic, strong) CNMoonlightPyroWaveDecoder *decoder;
@end

@implementation SteamPyroWaveBridge
- (instancetype)initWithWidth:(int)width height:(int)height {
    self = [super init];
    if (self) _decoder = [[CNMoonlightPyroWaveDecoder alloc] initWithWidth:width height:height];
    return self;
}
- (BOOL)isAvailable { return self.decoder.isAvailable; }
- (NSString *)statusMessage { return self.decoder.statusMessage ?: @"PyroWave decoder unavailable"; }
- (void)cancel { [self.decoder cancelSteamPackets]; }
- (void)submitPacket:(NSData *)packet completion:(void (^)(CNPyroWaveGPUFrame *, NSString *))completion {
    if (!self.decoder || packet.length == 0) { completion(nil, self.statusMessage); return; }
    [self.decoder submitSteamPacket:packet completion:completion];
}
@end
