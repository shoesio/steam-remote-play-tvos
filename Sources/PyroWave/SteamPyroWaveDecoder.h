#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

@interface SteamPyroWaveDecoder : NSObject
- (instancetype)initWithDevice:(id<MTLDevice>)device width:(int)width height:(int)height;
- (BOOL)pushPacket:(NSData *)packet;
- (BOOL)decodeReady:(BOOL)allowPartial;
- (BOOL)decodeWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                          luma:(id<MTLTexture>)luma
                         chromaB:(id<MTLTexture>)chromaB
                         chromaR:(id<MTLTexture>)chromaR;
@end
