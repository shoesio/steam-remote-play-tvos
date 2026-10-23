#import "CNMoonlightPyroWaveMetalRenderer.h"
#import "CNPyroWaveGPUFrame.h"
#import "Steam-Swift.h"

#import <os/proc.h>
#import <mach/mach.h>
#import <malloc/malloc.h>

@import Metal;

@interface CNMoonlightPyroWaveMetalRenderer ()
@property (nonatomic, strong) CAMetalLayer *metalLayer;
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property (nonatomic, strong) id<MTLSamplerState> sampler;
@property (nonatomic, assign) NSUInteger renderedFrameCount;
@property (nonatomic, assign) NSUInteger droppedFrameCount;
@property (nonatomic, assign) CFTimeInterval decodeToRenderDurationTotal;
@property (nonatomic, assign) CFTimeInterval presentationDurationTotal;
@end

@implementation CNMoonlightPyroWaveMetalRenderer

- (instancetype)initWithMetalLayer:(CAMetalLayer *)metalLayer {
    self = [super init];
    if (self) {
        _metalLayer = metalLayer;
    }
    return self;
}

- (BOOL)prepareForFrame:(CNPyroWaveGPUFrame *)frame error:(NSString **)error {
    id<MTLDevice> frameDevice = frame.lumaTexture.device;
    if (self.pipeline && self.device == frameDevice && self.commandQueue == frame.commandQueue) {
        return YES;
    }

    self.device = frameDevice;
    self.commandQueue = frame.commandQueue;
    if (self.metalLayer.device != frameDevice) {
        if (error) *error = @"PyroWave Metal layer and Vulkan textures use different devices";
        return NO;
    }

    static NSString *const shaderSource =
        @"#include <metal_stdlib>\n"
         "using namespace metal;\n"
         "struct VOut { float4 position [[position]]; float2 uv; };\n"
         "vertex VOut vertexMain(uint vid [[vertex_id]]) {\n"
         "  const float2 p[4] = { {-1,-1}, {-1,1}, {1,-1}, {1,1} };\n"
         "  const float2 t[4] = { {0,1}, {0,0}, {1,1}, {1,0} };\n"
         "  VOut o; o.position=float4(p[vid],0,1); o.uv=t[vid]; return o;\n"
         "}\n"
         "fragment float4 fragmentMain(VOut in [[stage_in]],\n"
         " texture2d<float> yTex [[texture(0)]], texture2d<float> cbTex [[texture(1)]],\n"
         " texture2d<float> crTex [[texture(2)]], sampler s [[sampler(0)]]) {\n"
         "  float y=yTex.sample(s,in.uv).r-16.0/255.0;\n"
         "  float cb=(cbTex.sample(s,in.uv).r-0.5)*(255.0/224.0);\n"
         "  float cr=(crTex.sample(s,in.uv).r-0.5)*(255.0/224.0);\n"
         "  y=clamp(y*(255.0/219.0),0.0,1.0); cb=clamp(cb,-0.5,0.5); cr=clamp(cr,-0.5,0.5);\n"
         "  float3 rgb=float3(y+1.5748*cr, y-0.187324*cb-0.468124*cr, y+1.8556*cb);\n"
         "  return float4(rgb,1.0);\n"
         "}\n";

    NSError *libraryError = nil;
    id<MTLLibrary> library = [frameDevice newLibraryWithSource:shaderSource options:nil error:&libraryError];
    if (!library) {
        if (error) *error = [NSString stringWithFormat:@"Metal shader compile failed: %@", libraryError.localizedDescription];
        return NO;
    }

    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = [library newFunctionWithName:@"vertexMain"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"fragmentMain"];
    descriptor.colorAttachments[0].pixelFormat = self.metalLayer.pixelFormat;
    self.pipeline = [frameDevice newRenderPipelineStateWithDescriptor:descriptor error:&libraryError];
    if (!self.pipeline) {
        if (error) *error = [NSString stringWithFormat:@"Metal pipeline creation failed: %@", libraryError.localizedDescription];
        return NO;
    }

    MTLSamplerDescriptor *samplerDescriptor = [[MTLSamplerDescriptor alloc] init];
    samplerDescriptor.minFilter = MTLSamplerMinMagFilterLinear;
    samplerDescriptor.magFilter = MTLSamplerMinMagFilterLinear;
    samplerDescriptor.sAddressMode = MTLSamplerAddressModeClampToEdge;
    samplerDescriptor.tAddressMode = MTLSamplerAddressModeClampToEdge;
    self.sampler = [frameDevice newSamplerStateWithDescriptor:samplerDescriptor];
    return self.sampler != nil;
}

- (BOOL)renderFrame:(CNPyroWaveGPUFrame *)frame error:(NSString **)error {
    if (![self prepareForFrame:frame error:error]) {
        self.droppedFrameCount += 1;
        [frame markPresentationCompleteAtTime:CACurrentMediaTime()];
        return NO;
    }

    id<CAMetalDrawable> drawable = [self.metalLayer nextDrawable];
    if (!drawable) {
        self.droppedFrameCount += 1;
        [frame markPresentationCompleteAtTime:CACurrentMediaTime()];
        if (error) *error = @"Metal drawable unavailable";
        return NO;
    }

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    CFTimeInterval presentationSubmitted = CACurrentMediaTime();
    CFTimeInterval decodeSubmitted = frame.decodeSubmittedTime;
    commandBuffer.label = @"CloudNow PyroWave YUV presentation";
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:self.pipeline];
    [encoder setFragmentTexture:frame.lumaTexture atIndex:0];
    [encoder setFragmentTexture:frame.cbTexture atIndex:1];
    [encoder setFragmentTexture:frame.crTexture atIndex:2];
    [encoder setFragmentSamplerState:self.sampler atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];
    [[AmbientLightingController shared] encodeWithLumaTexture:frame.lumaTexture
                                                   cbTexture:frame.cbTexture
                                                   crTexture:frame.crTexture
                                               commandBuffer:commandBuffer];
    [commandBuffer presentDrawable:drawable];

    __weak typeof(self) weakSelf = self;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completedBuffer) {
        @autoreleasepool {
        CFTimeInterval completed = CACurrentMediaTime();
        [frame markPresentationCompleteAtTime:completed];
        CNMoonlightPyroWaveMetalRenderer *strongSelf = weakSelf;
        if (!strongSelf) return;
        @synchronized (strongSelf) {
            strongSelf.renderedFrameCount += 1;
            strongSelf.decodeToRenderDurationTotal += completed - decodeSubmitted;
            strongSelf.presentationDurationTotal += completed - presentationSubmitted;
            if (completedBuffer.status == MTLCommandBufferStatusError) {
                strongSelf.droppedFrameCount += 1;
            }
            if (strongSelf.renderedFrameCount % 600 == 0) {
                double availableMemoryMB = (double)os_proc_available_memory() / (1024.0 * 1024.0);
                malloc_statistics_t mallocStats = {};
                malloc_zone_statistics(NULL, &mallocStats);
                task_vm_info_data_t vmInfo = {};
                mach_msg_type_number_t vmInfoCount = TASK_VM_INFO_COUNT;
                kern_return_t vmResult = task_info(mach_task_self(),
                                                   TASK_VM_INFO,
                                                   (task_info_t)&vmInfo,
                                                   &vmInfoCount);
                double mallocMB = (double)mallocStats.size_in_use / (1024.0 * 1024.0);
                double footprintMB = vmResult == KERN_SUCCESS
                    ? (double)vmInfo.phys_footprint / (1024.0 * 1024.0)
                    : -1.0;
                NSLog(@"[CNMoonlightPyroWaveMetalRenderer] perf rendered=%lu drops=%lu decodeToPresent=%.2fms presentation=%.2fms availableMem=%.0fMB malloc=%.0fMB footprint=%.0fMB",
                      (unsigned long)strongSelf.renderedFrameCount,
                      (unsigned long)strongSelf.droppedFrameCount,
                      strongSelf.decodeToRenderDurationTotal * 1000.0 / strongSelf.renderedFrameCount,
                      strongSelf.presentationDurationTotal * 1000.0 / strongSelf.renderedFrameCount,
                      availableMemoryMB,
                      mallocMB,
                      footprintMB);
            }
        }
        }
    }];
    [commandBuffer commit];
    return YES;
}

@end
