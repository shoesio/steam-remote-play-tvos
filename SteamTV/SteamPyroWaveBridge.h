#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import "CNPyroWaveGPUFrame.h"

NS_ASSUME_NONNULL_BEGIN

@interface SteamPyroWaveBridge : NSObject
- (instancetype)initWithWidth:(int)width height:(int)height;
- (BOOL)isAvailable;
- (NSString *)statusMessage;
- (void)cancel;
- (void)submitPacket:(NSData *)packet completion:(void (^)(CNPyroWaveGPUFrame *_Nullable frame, NSString *_Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
