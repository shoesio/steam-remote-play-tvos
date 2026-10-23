#import "SteamPyroWaveDecoder.h"
#include "pyrowave_metal.h"

@interface SteamPyroWaveDecoder ()
@property(nonatomic) pyrowave_device device;
@property(nonatomic) pyrowave_decoder decoder;
@end

@implementation SteamPyroWaveDecoder
- (instancetype)initWithDevice:(id<MTLDevice>)device width:(int)width height:(int)height {
    self = [super init];
    if (!self) return nil;
    if (!device || !pyrowave_device_is_supported((__bridge void *)device)) return nil;
    pyrowave_device_create_info deviceInfo = {};
    deviceInfo.mtl_device = (__bridge void *)device;
    if (pyrowave_device_create(&deviceInfo, &_device) != PYROWAVE_SUCCESS) return nil;
    pyrowave_decoder_create_info decoderInfo = {};
    decoderInfo.device = _device; decoderInfo.width = width; decoderInfo.height = height;
    decoderInfo.chroma = PYROWAVE_CHROMA_SUBSAMPLING_420;
    if (pyrowave_decoder_create(&decoderInfo, &_decoder) != PYROWAVE_SUCCESS) {
        pyrowave_device_destroy(_device); _device = nullptr; return nil;
    }
    return self;
}
- (void)dealloc {
    if (_decoder) pyrowave_decoder_destroy(_decoder);
    if (_device) pyrowave_device_destroy(_device);
}
- (BOOL)pushPacket:(NSData *)packet {
    return packet.length > 0 && pyrowave_decoder_push_packet(_decoder, packet.bytes, packet.length) == PYROWAVE_SUCCESS;
}
- (BOOL)decodeReady:(BOOL)allowPartial {
    return pyrowave_decoder_decode_is_ready(_decoder, allowPartial);
}
- (BOOL)decodeWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                           luma:(id<MTLTexture>)luma
                          chromaB:(id<MTLTexture>)chromaB
                          chromaR:(id<MTLTexture>)chromaR {
    pyrowave_gpu_buffers buffers = {};
    buffers.planes[0] = (__bridge void *)luma;
    buffers.planes[1] = (__bridge void *)chromaB;
    buffers.planes[2] = (__bridge void *)chromaR;
    return pyrowave_decoder_decode_gpu_buffer(_decoder, (__bridge void *)commandBuffer, &buffers) == PYROWAVE_SUCCESS;
}
@end
