#import "CNMoonlightPyroWaveDecoder.h"
#import "CNPyroWaveGPUFrame.h"
#import "CNPyroWaveVulkanInterop.h"

#import <dlfcn.h>
#import <stdlib.h>

@import AVFoundation;
@import CoreVideo;
@import Metal;
@import QuartzCore;

typedef enum pyrowave_result {
    PYROWAVE_SUCCESS = 0,
    PYROWAVE_ERROR_GENERIC = -1,
    PYROWAVE_ERROR_INVALID_ARGUMENT = -2,
    PYROWAVE_ERROR_OUT_OF_HOST_MEMORY = -3,
    PYROWAVE_ERROR_OUT_OF_DEVICE_MEMORY = -4,
    PYROWAVE_ERROR_NO_VULKAN = -5,
    PYROWAVE_ERROR_NOT_IMPLEMENTED = -6,
    PYROWAVE_ERROR_UNSUPPORTED_EXTERNAL_HANDLE = -7,
    PYROWAVE_ERROR_FAILED_EXTERNAL_HANDLE = -8
} pyrowave_result;

typedef enum pyrowave_chroma_subsampling {
    PYROWAVE_CHROMA_SUBSAMPLING_420 = 0
} pyrowave_chroma_subsampling;

typedef enum pyrowave_cpu_buffer_format {
    PYROWAVE_CPU_BUFFER_FORMAT_YUV420P = 1
} pyrowave_cpu_buffer_format;

typedef struct pyrowave_device_opaque *pyrowave_device;
typedef struct pyrowave_decoder_opaque *pyrowave_decoder;

typedef struct pyrowave_image_view {
    CNVkImage image;
    uint32_t width;
    uint32_t height;
    CNVkFormat image_format;
    CNVkFormat view_format;
    uint32_t mip_level;
    uint32_t layer;
    CNVkFlags aspect;
    int32_t swizzle;
    CNVkImageLayout layout;
} pyrowave_image_view;

typedef struct pyrowave_gpu_buffers {
    pyrowave_image_view planes[3];
} pyrowave_gpu_buffers;

typedef struct CNPyroWaveSyncPoint {
    CNVkSemaphore semaphore;
    uint64_t value;
} CNPyroWaveSyncPoint;

typedef struct CNPyroWaveGPUSyncOperation {
    const void *images;
    size_t numImages;
    CNPyroWaveSyncPoint sync;
} CNPyroWaveGPUSyncOperation;

typedef struct pyrowave_decoder_create_info {
    pyrowave_device device;
    int width;
    int height;
    pyrowave_chroma_subsampling chroma;
    bool fragment_path;
} pyrowave_decoder_create_info;

typedef struct pyrowave_cpu_buffer {
    void *data[3];
    size_t row_stride_in_bytes[3];
    size_t plane_size_in_bytes[3];
    int width;
    int height;
    pyrowave_cpu_buffer_format format;
} pyrowave_cpu_buffer;

typedef void (*CNPyroWaveGetAPIVersionFn)(uint32_t *major, uint32_t *minor, uint32_t *patch);
typedef const char *(*CNPyroWaveGetLastErrorFn)(void);
typedef pyrowave_result (*CNPyroWaveCreateDefaultDeviceFn)(pyrowave_device *device);
typedef bool (*CNPyroWaveDecoderDevicePrefersFragmentPathFn)(pyrowave_device device);
typedef pyrowave_result (*CNPyroWaveDecoderCreateFn)(const pyrowave_decoder_create_info *info, pyrowave_decoder *decoder);
typedef void (*CNPyroWaveDecoderClearFn)(pyrowave_decoder decoder);
typedef pyrowave_result (*CNPyroWaveDecoderPushPacketFn)(pyrowave_decoder decoder, const void *data, size_t size);
typedef bool (*CNPyroWaveDecoderDecodeIsReadyFn)(pyrowave_decoder decoder, bool allow_partial_frame);
typedef pyrowave_result (*CNPyroWaveDecoderDecodeCPUBufferSynchronousFn)(pyrowave_decoder decoder, const pyrowave_cpu_buffer *buffers);
typedef pyrowave_result (*CNPyroWaveDecoderDecodeGPUBufferFn)(pyrowave_decoder decoder, const void *acquire, const void *release, const pyrowave_gpu_buffers *buffers);
typedef void (*CNPyroWaveDeviceGetVkDeviceHandlesFn)(pyrowave_device pyroDevice, CNVkInstance *instance, CNVkPhysicalDevice *physicalDevice, CNVkDevice *vkDevice);
typedef void (*CNPyroWaveDeviceSetCommandBufferFn)(pyrowave_device pyroDevice, CNVkCommandBuffer commandBuffer);
typedef void (*CNPyroWaveDecoderDestroyFn)(pyrowave_decoder decoder);
typedef void (*CNPyroWaveDeviceDestroyFn)(pyrowave_device device);
typedef void (*CNVkGetMTLTextureMVKFn)(CNVkImage image, id<MTLTexture> *texture);
typedef void (*CNVkGetMTLCommandQueueMVKFn)(CNVkQueue queue, id<MTLCommandQueue> *commandQueue);

static const NSUInteger CNPyroWaveGPUFrameRingSize = 3;

@interface CNPyroWaveGPUFrame ()
@property (nonatomic, strong, readwrite) id<MTLTexture> lumaTexture;
@property (nonatomic, strong, readwrite) id<MTLTexture> cbTexture;
@property (nonatomic, strong, readwrite) id<MTLTexture> crTexture;
@property (nonatomic, strong, readwrite) id<MTLCommandQueue> commandQueue;
@property (nonatomic, assign, readwrite) uint64_t sequenceNumber;
@property (nonatomic, assign, readwrite) CFTimeInterval decodeSubmittedTime;
@property (nonatomic, assign) NSUInteger slotIndex;
@property (nonatomic, copy) void (^presentationCompletion)(NSUInteger slotIndex, uint64_t sequenceNumber, CFTimeInterval completionTime);
@property (atomic, assign) BOOL presentationCompleted;
@end

@implementation CNPyroWaveGPUFrame
- (void)markPresentationCompleteAtTime:(CFTimeInterval)completionTime {
    @synchronized (self) {
        if (self.presentationCompleted) return;
        self.presentationCompleted = YES;
    }
    if (self.presentationCompletion) {
        self.presentationCompletion(self.slotIndex, self.sequenceNumber, completionTime);
    }
}
@end

typedef struct CNPyroWaveGPUResourceSlot {
    CNVkImage images[3];
    CNVkDeviceMemory memories[3];
    CNVkCommandBuffer decodeCommandBuffer;
    CNVkSemaphore decodeCompleteSemaphore;
    bool inUse;
    uint64_t sequenceNumber;
} CNPyroWaveGPUResourceSlot;

@interface CNMoonlightPyroWaveDecoder ()
@property (nonatomic, assign) int width;
@property (nonatomic, assign) int height;
@property (nonatomic, assign) void *libraryHandle;
@property (nonatomic, assign) pyrowave_device device;
@property (nonatomic, assign) pyrowave_decoder decoder;
@property (nonatomic, copy, readwrite) NSString *statusMessage;
@property (nonatomic, assign, readwrite, getter=isAvailable) BOOL available;
@property (nonatomic, strong) NSMutableData *frameBuffer;
@property (nonatomic, assign) CVPixelBufferPoolRef pixelBufferPool;
@property (nonatomic, assign) CMVideoFormatDescriptionRef outputFormatDescription;
@property (nonatomic, assign) CNPyroWaveGetAPIVersionFn getAPIVersion;
@property (nonatomic, assign) CNPyroWaveCreateDefaultDeviceFn createDefaultDevice;
@property (nonatomic, assign) CNPyroWaveDecoderDevicePrefersFragmentPathFn decoderDevicePrefersFragmentPath;
@property (nonatomic, assign) CNPyroWaveDecoderCreateFn decoderCreate;
@property (nonatomic, assign) CNPyroWaveDecoderClearFn decoderClear;
@property (nonatomic, assign) CNPyroWaveDecoderPushPacketFn decoderPushPacket;
@property (nonatomic, assign) CNPyroWaveDecoderDecodeIsReadyFn decoderDecodeIsReady;
@property (nonatomic, assign) CNPyroWaveDecoderDecodeCPUBufferSynchronousFn decoderDecodeCPUBufferSynchronous;
@property (nonatomic, assign) CNPyroWaveDecoderDecodeGPUBufferFn decoderDecodeGPUBuffer;
@property (nonatomic, assign) CNPyroWaveDeviceGetVkDeviceHandlesFn deviceGetVkDeviceHandles;
@property (nonatomic, assign) CNPyroWaveDeviceSetCommandBufferFn deviceSetCommandBuffer;
@property (nonatomic, assign) CNPyroWaveDecoderDestroyFn decoderDestroy;
@property (nonatomic, assign) CNPyroWaveDeviceDestroyFn deviceDestroy;
@property (nonatomic, assign) NSUInteger pushedPacketCount;
@property (nonatomic, assign) NSUInteger decodedFrameCount;
@property (nonatomic, assign) NSUInteger waitingPacketLogCount;
@property (nonatomic, assign) NSUInteger failureLogCount;
@property (nonatomic, assign) BOOL didLogLumaOnlyDiagnostic;
@property (nonatomic, assign) BOOL didLogSyntheticDiagnostic;
@property (nonatomic, assign) CNPyroWaveGetLastErrorFn getLastError;
@property (nonatomic, assign) CFTimeInterval decodeDurationTotal;
@property (nonatomic, assign) CFTimeInterval outputDurationTotal;
@property (nonatomic, assign) NSUInteger pixelBufferPoolExhaustionCount;
@property (nonatomic, strong) dispatch_queue_t decodeQueue;
@property (nonatomic, assign) NSUInteger steamPendingBytes;
@property (nonatomic, assign) BOOL steamCancelled;
@property (nonatomic, assign) NSUInteger steamRejectedPackets;
@property (nonatomic, assign) CFTimeInterval steamLastErrorTime;
@property (nonatomic, assign) BOOL decodeInFlight;
@property (nonatomic, assign) BOOL needsFreshSourceFrame;
@property (nonatomic, assign) NSUInteger overloadDropCount;
@property (nonatomic, assign) NSUInteger overloadSourceFrameCount;
@property (nonatomic, assign) BOOL hasPendingSourceFrame;
@property (nonatomic, assign) uint32_t activeSourceFrame;
@property (nonatomic, assign) uint16_t nextSourceGroupIndex;
@property (nonatomic, assign) uint16_t activeSourceGroupCount;
@property (nonatomic, assign, readwrite, getter=isGPUPathAvailable) BOOL GPUPathAvailable;
@property (nonatomic, assign) void *vulkanLibraryHandle;
@property (nonatomic, assign) CNVkInstance vkInstance;
@property (nonatomic, assign) CNVkPhysicalDevice vkPhysicalDevice;
@property (nonatomic, assign) CNVkDevice vkDevice;
@property (nonatomic, assign) CNVkQueue vkQueue;
@property (nonatomic, assign) uint32_t vkQueueFamilyIndex;
@property (nonatomic, assign) CNVkCommandPool vkCommandPool;
@property (nonatomic, strong) id<MTLCommandQueue> metalCommandQueue;
@property (nonatomic, strong) NSArray<CNPyroWaveGPUFrame *> *GPUFrames;
@property (nonatomic, assign) CNPyroWaveGPUResourceSlot *GPUResourceSlots;
@property (nonatomic, assign) uint64_t nextGPUSequenceNumber;
@property (nonatomic, assign) NSUInteger GPUInFlightCount;
@property (nonatomic, assign) NSUInteger GPUFrameDropCount;
@property (nonatomic, assign) NSUInteger GPUDecodedFrameCount;
@property (nonatomic, assign) NSUInteger GPUCompletedFrameCount;
@property (nonatomic, assign) CFTimeInterval GPUSubmissionDurationTotal;
@property (nonatomic, assign) CFTimeInterval GPUFrameDurationTotal;
@property (nonatomic, assign) CNPFN_vkCreateImage vkCreateImage;
@property (nonatomic, assign) CNPFN_vkDestroyImage vkDestroyImage;
@property (nonatomic, assign) CNPFN_vkGetImageMemoryRequirements vkGetImageMemoryRequirements;
@property (nonatomic, assign) CNPFN_vkAllocateMemory vkAllocateMemory;
@property (nonatomic, assign) CNPFN_vkFreeMemory vkFreeMemory;
@property (nonatomic, assign) CNPFN_vkBindImageMemory vkBindImageMemory;
@property (nonatomic, assign) CNPFN_vkGetPhysicalDeviceMemoryProperties vkGetPhysicalDeviceMemoryProperties;
@property (nonatomic, assign) CNPFN_vkGetPhysicalDeviceQueueFamilyProperties vkGetPhysicalDeviceQueueFamilyProperties;
@property (nonatomic, assign) CNPFN_vkGetDeviceQueue vkGetDeviceQueue;
@property (nonatomic, assign) CNPFN_vkCreateCommandPool vkCreateCommandPool;
@property (nonatomic, assign) CNPFN_vkDestroyCommandPool vkDestroyCommandPool;
@property (nonatomic, assign) CNPFN_vkAllocateCommandBuffers vkAllocateCommandBuffers;
@property (nonatomic, assign) CNPFN_vkResetCommandBuffer vkResetCommandBuffer;
@property (nonatomic, assign) CNPFN_vkBeginCommandBuffer vkBeginCommandBuffer;
@property (nonatomic, assign) CNPFN_vkEndCommandBuffer vkEndCommandBuffer;
@property (nonatomic, assign) CNPFN_vkCmdPipelineBarrier vkCmdPipelineBarrier;
@property (nonatomic, assign) CNPFN_vkQueueSubmit vkQueueSubmit;
@property (nonatomic, assign) CNPFN_vkQueueWaitIdle vkQueueWaitIdle;
@property (nonatomic, assign) CNPFN_vkCreateSemaphore vkCreateSemaphore;
@property (nonatomic, assign) CNPFN_vkDestroySemaphore vkDestroySemaphore;
@property (nonatomic, assign) CNVkGetMTLTextureMVKFn vkGetMTLTextureMVK;
@property (nonatomic, assign) CNVkGetMTLCommandQueueMVKFn vkGetMTLCommandQueueMVK;
@end

static void CNPlaneStats(const uint8_t *bytes, NSUInteger length, uint8_t *minValue, uint8_t *maxValue, uint64_t *avgValue) {
    NSUInteger sampleCount = MIN(length, (NSUInteger)4096);
    NSUInteger step = MAX((NSUInteger)1, length / MAX(sampleCount, (NSUInteger)1));
    NSUInteger actualSamples = 0;
    uint8_t minSample = UINT8_MAX;
    uint8_t maxSample = 0;
    uint64_t sum = 0;

    for (NSUInteger i = 0; i < length && actualSamples < sampleCount; i += step) {
        uint8_t value = bytes[i];
        minSample = MIN(minSample, value);
        maxSample = MAX(maxSample, value);
        sum += value;
        actualSamples += 1;
    }

    *minValue = actualSamples > 0 ? minSample : 0;
    *maxValue = actualSamples > 0 ? maxSample : 0;
    *avgValue = actualSamples > 0 ? sum / actualSamples : 0;
}

static uint64_t CNPyroWavePacketHash(NSData *data) {
    const uint8_t *bytes = data.bytes;
    uint64_t hash = 1469598103934665603ULL;
    for (NSUInteger i = 0; i < data.length; i++) {
        hash ^= bytes[i];
        hash *= 1099511628211ULL;
    }
    return hash;
}

typedef struct CNPyroWaveTransportInfo {
    NSUInteger headerLength;
    uint32_t sourceFrame;
    uint16_t groupIndex;
    uint16_t groupCount;
    BOOL hasSourceFrame;
} CNPyroWaveTransportInfo;

static BOOL CNPyroWaveReadTransportInfo(const uint8_t *bytes, NSUInteger length, CNPyroWaveTransportInfo *info) {
    if (!bytes || !info || length < 4) {
        return NO;
    }

    memset(info, 0, sizeof(*info));
    if (memcmp(bytes, "PWF1", 4) == 0) {
        info->headerLength = 4;
        return YES;
    }
    if (length < 12 || memcmp(bytes, "PWF2", 4) != 0) {
        return NO;
    }

    info->headerLength = 12;
    info->sourceFrame = ((uint32_t)bytes[4] << 24)
        | ((uint32_t)bytes[5] << 16)
        | ((uint32_t)bytes[6] << 8)
        | (uint32_t)bytes[7];
    info->groupIndex = ((uint16_t)bytes[8] << 8) | (uint16_t)bytes[9];
    info->groupCount = ((uint16_t)bytes[10] << 8) | (uint16_t)bytes[11];
    info->hasSourceFrame = info->groupCount > 0 && info->groupIndex < info->groupCount;
    return info->hasSourceFrame;
}

@implementation CNMoonlightPyroWaveDecoder

- (instancetype)initWithWidth:(int)width height:(int)height {
    self = [super init];
    if (self) {
        _width = width;
        _height = height;
        _statusMessage = @"PyroWave decoder not initialized";
        _frameBuffer = [NSMutableData data];
        _decodeQueue = dispatch_queue_create("com.cloudnow.pyrowave.decode", DISPATCH_QUEUE_SERIAL);
        [self configurePixelBufferPool];
        [self initializeDecoder];
    }
    return self;
}

- (void)dealloc {
    // Drain the shared MoltenVK/Metal queue and release output images while the
    // decoder's pipelines are still alive. Destroying the decoder first could
    // race an asynchronously submitted GPU decode.
    [self destroyGPUInterop];
    if (self.decoder && self.decoderDestroy) {
        self.decoderDestroy(self.decoder);
        self.decoder = NULL;
    }
    if (self.device && self.deviceDestroy) {
        self.deviceDestroy(self.device);
    }
    if (self.libraryHandle) {
        dlclose(self.libraryHandle);
    }
    if (self.outputFormatDescription) {
        CFRelease(self.outputFormatDescription);
    }
    if (self.pixelBufferPool) {
        CVPixelBufferPoolRelease(self.pixelBufferPool);
    }
}

- (void)configurePixelBufferPool {
    NSDictionary *poolAttributes = @{
        (NSString *)kCVPixelBufferPoolMinimumBufferCountKey: @6
    };
    NSDictionary *pixelBufferAttributes = @{
        // PyroWave produces separate Y, U, and V planes. Decode directly
        // into Core Video's matching planar layout to avoid an extra 1440p
        // CPU copy and U/V interleave before every presentation.
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8Planar),
        (NSString *)kCVPixelBufferWidthKey: @(self.width),
        (NSString *)kCVPixelBufferHeightKey: @(self.height),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (NSString *)kCVPixelBufferMetalCompatibilityKey: @YES
    };

    CVReturn result = CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        (__bridge CFDictionaryRef)poolAttributes,
        (__bridge CFDictionaryRef)pixelBufferAttributes,
        &_pixelBufferPool
    );
    if (result != kCVReturnSuccess || !self.pixelBufferPool) {
        NSLog(@"[CNMoonlightPyroWaveDecoder] Failed to create pixel buffer pool: %d", result);
        return;
    }

    CVPixelBufferRef pixelBuffer = NULL;
    result = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, self.pixelBufferPool, &pixelBuffer);
    if (result != kCVReturnSuccess || !pixelBuffer) {
        NSLog(@"[CNMoonlightPyroWaveDecoder] Failed to allocate pixel buffer pool probe: %d", result);
        return;
    }

    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(
        kCFAllocatorDefault,
        pixelBuffer,
        &_outputFormatDescription
    );
    CVPixelBufferRelease(pixelBuffer);
    if (status != noErr || !self.outputFormatDescription) {
        NSLog(@"[CNMoonlightPyroWaveDecoder] Failed to create output format description: %d", (int)status);
    }
}

- (void)initializeDecoder {
    self.libraryHandle = [self openPyroWaveLibrary];
    if (!self.libraryHandle) {
        self.statusMessage = @"PyroWave dylib not bundled";
        return;
    }

    if (![self loadSymbols]) {
        self.statusMessage = @"PyroWave dylib missing decoder symbols";
        return;
    }

    [self configureMoltenVKLoaderPath];

    uint32_t major = 0;
    uint32_t minor = 0;
    uint32_t patch = 0;
    self.getAPIVersion(&major, &minor, &patch);

    pyrowave_result result = self.createDefaultDevice(&_device);
    if (result != PYROWAVE_SUCCESS) {
        self.statusMessage = [NSString stringWithFormat:@"pyrowave_create_default_device failed: %d%@",
                              (int)result,
                              [self formattedLastPyroWaveError]];
        return;
    }

    bool preferredFragmentPath = self.decoderDevicePrefersFragmentPath(self.device);
#if TARGET_OS_TV
    bool fragmentPath = true;
#else
    bool fragmentPath = preferredFragmentPath;
#endif
    NSLog(@"[CNMoonlightPyroWaveDecoder] Creating PyroWave decoder %dx%d, fragmentPath=%d preferred=%d",
          self.width,
          self.height,
          fragmentPath,
          preferredFragmentPath);

    pyrowave_decoder_create_info info = {};
    info.device = self.device;
    info.width = self.width;
    info.height = self.height;
    info.chroma = PYROWAVE_CHROMA_SUBSAMPLING_420;
    info.fragment_path = fragmentPath;

    result = self.decoderCreate(&info, &_decoder);
    if (result != PYROWAVE_SUCCESS) {
        self.statusMessage = [NSString stringWithFormat:@"pyrowave_decoder_create failed: %d (%dx%d fragment=%d preferred=%d)%@",
                              (int)result,
                              self.width,
                              self.height,
                              fragmentPath,
                              preferredFragmentPath,
                              [self formattedLastPyroWaveError]];
        return;
    }

    self.available = YES;
    NSString *GPUError = nil;
    if ([self initializeGPUInterop:&GPUError]) {
        self.GPUPathAvailable = YES;
        self.statusMessage = [NSString stringWithFormat:@"PyroWave C API %u.%u.%u GPU renderer ready", major, minor, patch];
    } else {
        self.GPUPathAvailable = NO;
        self.statusMessage = [NSString stringWithFormat:@"PyroWave C API %u.%u.%u CPU fallback ready (%@)",
                              major, minor, patch, GPUError ?: @"GPU interop unavailable"];
        NSLog(@"[CNMoonlightPyroWaveDecoder] GPU interop unavailable; preserving CPU fallback: %@", GPUError);
    }
}

- (void *)openPyroWaveLibrary {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    const char *overridePath = getenv("CN_PYROWAVE_DYLIB");
    if (overridePath && overridePath[0] != '\0') {
        [paths addObject:[NSString stringWithUTF8String:overridePath]];
    }

    NSBundle *bundle = NSBundle.mainBundle;
    NSString *frameworksPath = bundle.privateFrameworksPath;
    NSString *resourcesPath = bundle.resourcePath;
    if (frameworksPath.length > 0) {
        [paths addObject:[frameworksPath stringByAppendingPathComponent:@"libpyrowave-shared.0.dylib"]];
        [paths addObject:[frameworksPath stringByAppendingPathComponent:@"libpyrowave-shared.0.4.0.dylib"]];
    }
    if (resourcesPath.length > 0) {
        [paths addObject:[resourcesPath stringByAppendingPathComponent:@"libpyrowave-shared.0.dylib"]];
        [paths addObject:[resourcesPath stringByAppendingPathComponent:@"libpyrowave-shared.0.4.0.dylib"]];
    }

#if TARGET_OS_OSX
    [paths addObject:@"/private/tmp/pyrowave-prototype/pyrowave-build/libpyrowave-shared.0.4.0.dylib"];
#endif

    for (NSString *path in paths) {
        void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (handle) {
            return handle;
        }
    }

    return dlopen("libpyrowave-shared.0.dylib", RTLD_NOW | RTLD_LOCAL);
}

- (void)configureMoltenVKLoaderPath {
    NSString *frameworksPath = NSBundle.mainBundle.privateFrameworksPath;
    NSString *moltenVKPath = [frameworksPath stringByAppendingPathComponent:@"MoltenVK.framework/MoltenVK"];
    if (moltenVKPath.length == 0) {
        return;
    }

    if ([NSFileManager.defaultManager fileExistsAtPath:moltenVKPath]) {
        setenv("GRANITE_VULKAN_LIBRARY", moltenVKPath.fileSystemRepresentation, 1);
        // Granite can emit the same unsupported-feature warning once for each
        // pipeline it builds. Keep device logs concise unless a developer has
        // explicitly requested a more verbose MoltenVK level.
        setenv("MVK_CONFIG_LOG_LEVEL", "1", 0);
        NSLog(@"[CNMoonlightPyroWaveDecoder] GRANITE_VULKAN_LIBRARY=%@", moltenVKPath);
    } else {
        NSLog(@"[CNMoonlightPyroWaveDecoder] MoltenVK framework missing at %@", moltenVKPath);
    }
}

- (BOOL)loadSymbols {
    self.getAPIVersion = (CNPyroWaveGetAPIVersionFn)dlsym(self.libraryHandle, "pyrowave_get_api_version");
    self.getLastError = (CNPyroWaveGetLastErrorFn)dlsym(self.libraryHandle, "pyrowave_get_last_error");
    self.createDefaultDevice = (CNPyroWaveCreateDefaultDeviceFn)dlsym(self.libraryHandle, "pyrowave_create_default_device");
    self.decoderDevicePrefersFragmentPath = (CNPyroWaveDecoderDevicePrefersFragmentPathFn)dlsym(self.libraryHandle, "pyrowave_decoder_device_prefers_fragment_path");
    self.decoderCreate = (CNPyroWaveDecoderCreateFn)dlsym(self.libraryHandle, "pyrowave_decoder_create");
    self.decoderClear = (CNPyroWaveDecoderClearFn)dlsym(self.libraryHandle, "pyrowave_decoder_clear");
    self.decoderPushPacket = (CNPyroWaveDecoderPushPacketFn)dlsym(self.libraryHandle, "pyrowave_decoder_push_packet");
    self.decoderDecodeIsReady = (CNPyroWaveDecoderDecodeIsReadyFn)dlsym(self.libraryHandle, "pyrowave_decoder_decode_is_ready");
    self.decoderDecodeCPUBufferSynchronous = (CNPyroWaveDecoderDecodeCPUBufferSynchronousFn)dlsym(self.libraryHandle, "pyrowave_decoder_decode_cpu_buffer_synchronous");
    self.decoderDecodeGPUBuffer = (CNPyroWaveDecoderDecodeGPUBufferFn)dlsym(self.libraryHandle, "pyrowave_decoder_decode_gpu_buffer");
    self.deviceGetVkDeviceHandles = (CNPyroWaveDeviceGetVkDeviceHandlesFn)dlsym(self.libraryHandle, "pyrowave_device_get_vk_device_handles");
    self.deviceSetCommandBuffer = (CNPyroWaveDeviceSetCommandBufferFn)dlsym(self.libraryHandle, "pyrowave_device_set_command_buffer");
    self.decoderDestroy = (CNPyroWaveDecoderDestroyFn)dlsym(self.libraryHandle, "pyrowave_decoder_destroy");
    self.deviceDestroy = (CNPyroWaveDeviceDestroyFn)dlsym(self.libraryHandle, "pyrowave_device_destroy");

    return self.getAPIVersion
        && self.createDefaultDevice
        && self.decoderDevicePrefersFragmentPath
        && self.decoderCreate
        && self.decoderClear
        && self.decoderPushPacket
        && self.decoderDecodeIsReady
        && self.decoderDecodeCPUBufferSynchronous
        && self.decoderDestroy
        && self.deviceDestroy;
}

- (NSString *)formattedLastPyroWaveError {
    if (!self.getLastError) {
        return @"";
    }

    const char *lastError = self.getLastError();
    if (!lastError || lastError[0] == '\0') {
        return @"";
    }

    NSString *message = [NSString stringWithUTF8String:lastError];
    if (message.length == 0) {
        return @"";
    }

    return [NSString stringWithFormat:@": %@", message];
}

- (BOOL)loadVulkanInteropSymbols:(NSString **)error {
    NSString *path = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"MoltenVK.framework/MoltenVK"];
    self.vulkanLibraryHandle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!self.vulkanLibraryHandle) {
        if (error) *error = @"MoltenVK could not be opened for interop";
        return NO;
    }

#define CN_LOAD_VK(property, symbol) self.property = (__typeof__(self.property))dlsym(self.vulkanLibraryHandle, symbol)
    CN_LOAD_VK(vkCreateImage, "vkCreateImage");
    CN_LOAD_VK(vkDestroyImage, "vkDestroyImage");
    CN_LOAD_VK(vkGetImageMemoryRequirements, "vkGetImageMemoryRequirements");
    CN_LOAD_VK(vkAllocateMemory, "vkAllocateMemory");
    CN_LOAD_VK(vkFreeMemory, "vkFreeMemory");
    CN_LOAD_VK(vkBindImageMemory, "vkBindImageMemory");
    CN_LOAD_VK(vkGetPhysicalDeviceMemoryProperties, "vkGetPhysicalDeviceMemoryProperties");
    CN_LOAD_VK(vkGetPhysicalDeviceQueueFamilyProperties, "vkGetPhysicalDeviceQueueFamilyProperties");
    CN_LOAD_VK(vkGetDeviceQueue, "vkGetDeviceQueue");
    CN_LOAD_VK(vkCreateCommandPool, "vkCreateCommandPool");
    CN_LOAD_VK(vkDestroyCommandPool, "vkDestroyCommandPool");
    CN_LOAD_VK(vkAllocateCommandBuffers, "vkAllocateCommandBuffers");
    CN_LOAD_VK(vkResetCommandBuffer, "vkResetCommandBuffer");
    CN_LOAD_VK(vkBeginCommandBuffer, "vkBeginCommandBuffer");
    CN_LOAD_VK(vkEndCommandBuffer, "vkEndCommandBuffer");
    CN_LOAD_VK(vkCmdPipelineBarrier, "vkCmdPipelineBarrier");
    CN_LOAD_VK(vkQueueSubmit, "vkQueueSubmit");
    CN_LOAD_VK(vkQueueWaitIdle, "vkQueueWaitIdle");
    CN_LOAD_VK(vkCreateSemaphore, "vkCreateSemaphore");
    CN_LOAD_VK(vkDestroySemaphore, "vkDestroySemaphore");
    CN_LOAD_VK(vkGetMTLTextureMVK, "vkGetMTLTextureMVK");
    CN_LOAD_VK(vkGetMTLCommandQueueMVK, "vkGetMTLCommandQueueMVK");
#undef CN_LOAD_VK

    BOOL complete = self.vkCreateImage && self.vkDestroyImage && self.vkGetImageMemoryRequirements
        && self.vkAllocateMemory && self.vkFreeMemory && self.vkBindImageMemory
        && self.vkGetPhysicalDeviceMemoryProperties && self.vkGetPhysicalDeviceQueueFamilyProperties
        && self.vkGetDeviceQueue && self.vkCreateCommandPool && self.vkDestroyCommandPool
        && self.vkAllocateCommandBuffers && self.vkResetCommandBuffer
        && self.vkBeginCommandBuffer && self.vkEndCommandBuffer
        && self.vkCmdPipelineBarrier && self.vkQueueSubmit && self.vkQueueWaitIdle
        && self.vkCreateSemaphore && self.vkDestroySemaphore
        && self.vkGetMTLTextureMVK && self.vkGetMTLCommandQueueMVK;
    if (!complete && error) *error = @"MoltenVK is missing required GPU interop symbols";
    return complete;
}

- (NSInteger)deviceLocalMemoryTypeForBits:(uint32_t)memoryTypeBits {
    CNVkPhysicalDeviceMemoryProperties properties = {};
    self.vkGetPhysicalDeviceMemoryProperties(self.vkPhysicalDevice, &properties);
    for (uint32_t index = 0; index < properties.memoryTypeCount; index++) {
        if ((memoryTypeBits & (1u << index))
            && (properties.memoryTypes[index].propertyFlags & CNVK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
            return index;
        }
    }
    for (uint32_t index = 0; index < properties.memoryTypeCount; index++) {
        if (memoryTypeBits & (1u << index)) return index;
    }
    return NSNotFound;
}

- (BOOL)createGPUImageWidth:(uint32_t)width
                     height:(uint32_t)height
                      image:(CNVkImage *)image
                     memory:(CNVkDeviceMemory *)memory
                      error:(NSString **)error {
    CNVkImageCreateInfo imageInfo = {};
    imageInfo.sType = CNVK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    imageInfo.imageType = CNVK_IMAGE_TYPE_2D;
    imageInfo.format = CNVK_FORMAT_R8_UNORM;
    imageInfo.extent = (CNVkExtent3D){ width, height, 1 };
    imageInfo.mipLevels = 1;
    imageInfo.arrayLayers = 1;
    imageInfo.samples = CNVK_SAMPLE_COUNT_1_BIT;
    imageInfo.tiling = CNVK_IMAGE_TILING_OPTIMAL;
    imageInfo.usage = CNVK_IMAGE_USAGE_SAMPLED_BIT | CNVK_IMAGE_USAGE_STORAGE_BIT | CNVK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    imageInfo.sharingMode = CNVK_SHARING_MODE_EXCLUSIVE;
    imageInfo.initialLayout = CNVK_IMAGE_LAYOUT_UNDEFINED;

    CNVkResult result = self.vkCreateImage(self.vkDevice, &imageInfo, NULL, image);
    if (result != CNVK_SUCCESS) {
        if (error) *error = [NSString stringWithFormat:@"vkCreateImage failed: %d", result];
        return NO;
    }

    CNVkMemoryRequirements requirements = {};
    self.vkGetImageMemoryRequirements(self.vkDevice, *image, &requirements);
    NSInteger memoryType = [self deviceLocalMemoryTypeForBits:requirements.memoryTypeBits];
    if (memoryType == NSNotFound) {
        if (error) *error = @"No compatible Vulkan image memory type";
        return NO;
    }

    CNVkMemoryAllocateInfo allocation = {};
    allocation.sType = CNVK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    allocation.allocationSize = requirements.size;
    allocation.memoryTypeIndex = (uint32_t)memoryType;
    result = self.vkAllocateMemory(self.vkDevice, &allocation, NULL, memory);
    if (result != CNVK_SUCCESS) {
        if (error) *error = [NSString stringWithFormat:@"vkAllocateMemory failed: %d", result];
        return NO;
    }
    result = self.vkBindImageMemory(self.vkDevice, *image, *memory, 0);
    if (result != CNVK_SUCCESS) {
        if (error) *error = [NSString stringWithFormat:@"vkBindImageMemory failed: %d", result];
        return NO;
    }
    return YES;
}

- (BOOL)transitionGPUImagesToGeneral:(NSString **)error {
    CNVkCommandPoolCreateInfo poolInfo = {};
    poolInfo.sType = CNVK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    poolInfo.flags = CNVK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    poolInfo.queueFamilyIndex = self.vkQueueFamilyIndex;
    CNVkResult result = self.vkCreateCommandPool(self.vkDevice, &poolInfo, NULL, &_vkCommandPool);
    if (result != CNVK_SUCCESS) {
        if (error) *error = [NSString stringWithFormat:@"vkCreateCommandPool failed: %d", result];
        return NO;
    }

    CNVkCommandBuffer commandBuffer = NULL;
    CNVkCommandBufferAllocateInfo allocateInfo = {};
    allocateInfo.sType = CNVK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    allocateInfo.commandPool = self.vkCommandPool;
    allocateInfo.level = CNVK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocateInfo.commandBufferCount = 1;
    result = self.vkAllocateCommandBuffers(self.vkDevice, &allocateInfo, &commandBuffer);
    if (result != CNVK_SUCCESS) {
        if (error) *error = [NSString stringWithFormat:@"vkAllocateCommandBuffers failed: %d", result];
        return NO;
    }

    CNVkCommandBufferBeginInfo beginInfo = {};
    beginInfo.sType = CNVK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    beginInfo.flags = CNVK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    if (self.vkBeginCommandBuffer(commandBuffer, &beginInfo) != CNVK_SUCCESS) return NO;

    CNVkImageMemoryBarrier barriers[9] = {};
    for (NSUInteger slot = 0; slot < CNPyroWaveGPUFrameRingSize; slot++) {
        for (NSUInteger plane = 0; plane < 3; plane++) {
            CNVkImageMemoryBarrier *barrier = &barriers[slot * 3 + plane];
            barrier->sType = CNVK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
            barrier->srcAccessMask = 0;
            barrier->dstAccessMask = CNVK_ACCESS_SHADER_READ_BIT | CNVK_ACCESS_SHADER_WRITE_BIT | CNVK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
            barrier->oldLayout = CNVK_IMAGE_LAYOUT_UNDEFINED;
            barrier->newLayout = CNVK_IMAGE_LAYOUT_GENERAL;
            barrier->srcQueueFamilyIndex = CNVK_QUEUE_FAMILY_IGNORED;
            barrier->dstQueueFamilyIndex = CNVK_QUEUE_FAMILY_IGNORED;
            barrier->image = self.GPUResourceSlots[slot].images[plane];
            barrier->subresourceRange = (CNVkImageSubresourceRange){ CNVK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
        }
    }
    self.vkCmdPipelineBarrier(commandBuffer,
                              CNVK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                              CNVK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                              0, 0, NULL, 0, NULL,
                              (uint32_t)(CNPyroWaveGPUFrameRingSize * 3), barriers);
    if (self.vkEndCommandBuffer(commandBuffer) != CNVK_SUCCESS) return NO;

    CNVkSubmitInfo submit = {};
    submit.sType = CNVK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &commandBuffer;
    result = self.vkQueueSubmit(self.vkQueue, 1, &submit, NULL);
    if (result == CNVK_SUCCESS) result = self.vkQueueWaitIdle(self.vkQueue);
    if (result != CNVK_SUCCESS && error) *error = [NSString stringWithFormat:@"Vulkan image initialization failed: %d", result];
    return result == CNVK_SUCCESS;
}

- (BOOL)initializeGPUInterop:(NSString **)error {
    if (!self.decoderDecodeGPUBuffer || !self.deviceGetVkDeviceHandles || !self.deviceSetCommandBuffer) {
        if (error) *error = @"PyroWave GPU-buffer API symbols unavailable";
        return NO;
    }
    if (![self loadVulkanInteropSymbols:error]) return NO;

    self.deviceGetVkDeviceHandles(self.device, &_vkInstance, &_vkPhysicalDevice, &_vkDevice);
    if (!self.vkPhysicalDevice || !self.vkDevice) {
        if (error) *error = @"PyroWave did not expose its Vulkan device";
        return NO;
    }

    uint32_t queueCount = 0;
    self.vkGetPhysicalDeviceQueueFamilyProperties(self.vkPhysicalDevice, &queueCount, NULL);
    if (queueCount == 0) {
        if (error) *error = @"Vulkan device has no queue families";
        return NO;
    }
    CNVkQueueFamilyProperties *queues = calloc(queueCount, sizeof(*queues));
    self.vkGetPhysicalDeviceQueueFamilyProperties(self.vkPhysicalDevice, &queueCount, queues);
    self.vkQueueFamilyIndex = UINT32_MAX;
    for (uint32_t index = 0; index < queueCount; index++) {
        if ((queues[index].queueFlags & CNVK_QUEUE_GRAPHICS_BIT) && queues[index].queueCount > 0) {
            self.vkQueueFamilyIndex = index;
            break;
        }
    }
    free(queues);
    if (self.vkQueueFamilyIndex == UINT32_MAX) {
        if (error) *error = @"Vulkan device has no graphics queue";
        return NO;
    }
    self.vkGetDeviceQueue(self.vkDevice, self.vkQueueFamilyIndex, 0, &_vkQueue);
    id<MTLCommandQueue> commandQueue = nil;
    self.vkGetMTLCommandQueueMVK(self.vkQueue, &commandQueue);
    self.metalCommandQueue = commandQueue;
    if (!self.vkQueue || !self.metalCommandQueue) {
        if (error) *error = @"MoltenVK did not expose its Metal command queue";
        return NO;
    }

    self.GPUResourceSlots = calloc(CNPyroWaveGPUFrameRingSize, sizeof(*self.GPUResourceSlots));
    if (!self.GPUResourceSlots) {
        if (error) *error = @"Could not allocate GPU frame ring metadata";
        return NO;
    }

    NSMutableArray<CNPyroWaveGPUFrame *> *frames = [NSMutableArray arrayWithCapacity:CNPyroWaveGPUFrameRingSize];
    for (NSUInteger slot = 0; slot < CNPyroWaveGPUFrameRingSize; slot++) {
        CNPyroWaveGPUFrame *frame = [[CNPyroWaveGPUFrame alloc] init];
        frame.slotIndex = slot;
        frame.commandQueue = self.metalCommandQueue;
        for (NSUInteger plane = 0; plane < 3; plane++) {
            uint32_t planeWidth = plane == 0 ? (uint32_t)self.width : (uint32_t)self.width / 2;
            uint32_t planeHeight = plane == 0 ? (uint32_t)self.height : (uint32_t)self.height / 2;
            if (![self createGPUImageWidth:planeWidth
                                   height:planeHeight
                                    image:&self.GPUResourceSlots[slot].images[plane]
                                   memory:&self.GPUResourceSlots[slot].memories[plane]
                                    error:error]) return NO;
            id<MTLTexture> texture = nil;
            self.vkGetMTLTextureMVK(self.GPUResourceSlots[slot].images[plane], &texture);
            if (!texture) {
                if (error) *error = @"MoltenVK did not expose a Metal texture";
                return NO;
            }
            if (plane == 0) frame.lumaTexture = texture;
            else if (plane == 1) frame.cbTexture = texture;
            else frame.crTexture = texture;
        }
        [frames addObject:frame];
    }
    self.GPUFrames = frames;
    if (![self transitionGPUImagesToGeneral:error]) return NO;

    CNVkCommandBufferAllocateInfo commandBufferInfo = {};
    commandBufferInfo.sType = CNVK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    commandBufferInfo.commandPool = self.vkCommandPool;
    commandBufferInfo.level = CNVK_COMMAND_BUFFER_LEVEL_PRIMARY;
    commandBufferInfo.commandBufferCount = 1;
    CNVkSemaphoreCreateInfo semaphoreInfo = {};
    semaphoreInfo.sType = CNVK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    for (NSUInteger slot = 0; slot < CNPyroWaveGPUFrameRingSize; slot++) {
        CNVkResult result = self.vkAllocateCommandBuffers(self.vkDevice,
                                                          &commandBufferInfo,
                                                          &self.GPUResourceSlots[slot].decodeCommandBuffer);
        if (result != CNVK_SUCCESS) {
            if (error) *error = [NSString stringWithFormat:@"vkAllocateCommandBuffers for GPU slot failed: %d", result];
            return NO;
        }
        result = self.vkCreateSemaphore(self.vkDevice,
                                        &semaphoreInfo,
                                        NULL,
                                        &self.GPUResourceSlots[slot].decodeCompleteSemaphore);
        if (result != CNVK_SUCCESS) {
            if (error) *error = [NSString stringWithFormat:@"vkCreateSemaphore for GPU slot failed: %d", result];
            return NO;
        }
    }
    NSLog(@"[CNMoonlightPyroWaveDecoder] GPU-native ring ready slots=%lu planes=YUV420P size=%dx%d",
          (unsigned long)CNPyroWaveGPUFrameRingSize, self.width, self.height);
    return YES;
}

- (void)destroyGPUInterop {
    if (self.metalCommandQueue) {
        id<MTLCommandBuffer> drain = [self.metalCommandQueue commandBuffer];
        [drain commit];
        [drain waitUntilCompleted];
    }
    if (self.vkDevice && self.GPUResourceSlots) {
        for (NSUInteger slot = 0; slot < CNPyroWaveGPUFrameRingSize; slot++) {
            if (self.GPUResourceSlots[slot].decodeCompleteSemaphore && self.vkDestroySemaphore) {
                self.vkDestroySemaphore(self.vkDevice,
                                        self.GPUResourceSlots[slot].decodeCompleteSemaphore,
                                        NULL);
            }
            for (NSUInteger plane = 0; plane < 3; plane++) {
                if (self.GPUResourceSlots[slot].images[plane] && self.vkDestroyImage) {
                    self.vkDestroyImage(self.vkDevice, self.GPUResourceSlots[slot].images[plane], NULL);
                }
                if (self.GPUResourceSlots[slot].memories[plane] && self.vkFreeMemory) {
                    self.vkFreeMemory(self.vkDevice, self.GPUResourceSlots[slot].memories[plane], NULL);
                }
            }
        }
    }
    if (self.vkCommandPool && self.vkDestroyCommandPool) {
        self.vkDestroyCommandPool(self.vkDevice, self.vkCommandPool, NULL);
    }
    free(self.GPUResourceSlots);
    self.GPUResourceSlots = NULL;
    self.GPUFrames = nil;
    self.metalCommandQueue = nil;
    if (self.vulkanLibraryHandle) {
        dlclose(self.vulkanLibraryHandle);
        self.vulkanLibraryHandle = NULL;
    }
}

- (void)submitDecodeUnit:(PDECODE_UNIT)decodeUnit
               completion:(void (^)(CMSampleBufferRef _Nullable sampleBuffer, NSString *_Nullable error))completion {
    [self submitDecodeUnit:decodeUnit GPUFrameCompletion:^(CNPyroWaveGPUFrame *GPUFrame,
                                                           CMSampleBufferRef sampleBuffer,
                                                           NSString *error) {
        if (GPUFrame) {
            [GPUFrame markPresentationCompleteAtTime:CACurrentMediaTime()];
            completion(NULL, @"GPU frame requires the PyroWave Metal presentation path");
        } else {
            completion(sampleBuffer, error);
        }
    }];
}

- (void)submitDecodeUnit:(PDECODE_UNIT)decodeUnit
      GPUFrameCompletion:(void (^)(CNPyroWaveGPUFrame *_Nullable GPUFrame,
                                   CMSampleBufferRef _Nullable fallbackSampleBuffer,
                                   NSString *_Nullable error))completion {
    if (!completion) {
        return;
    }
    if (!self.available || !decodeUnit) {
        completion(nil, NULL, self.statusMessage);
        return;
    }

    // pushPacketizedData consumes the bytes synchronously and PyroWave copies
    // the packet words it needs. Do not duplicate the complete compressed
    // source group here: at 1440p that payload-sized NSData allocation was
    // retained by the Moonlight callback thread's lifetime and grew the heap
    // by roughly one frame per frame.
    NSData *frameData = [self packetizedDataForDecodeUnit:decodeUnit];
    if (frameData.length == 0) {
        completion(nil, NULL, @"PyroWave decode unit had no picture data");
        return;
    }

    CNPyroWaveTransportInfo transportInfo = {};
    if (!CNPyroWaveReadTransportInfo(frameData.bytes, frameData.length, &transportInfo) || !transportInfo.hasSourceFrame) {
        // PWF1 hosts predate source-frame metadata. Keep them compatible while
        // PWF2 is rolled out, even though their synchronous path is slower.
        NSString *error = nil;
        CMSampleBufferRef sampleBuffer = [self copySampleBufferForDecodeUnit:decodeUnit error:&error];
        completion(nil, sampleBuffer, error);
        return;
    }

    const uint32_t rtpTimestamp = decodeUnit->rtpTimestamp;
    const int64_t presentationTimeUs = decodeUnit->presentationTimeUs;
    __block BOOL shouldDecode = NO;
    __block NSString *immediateError = nil;

    @synchronized (self) {
        if (self.decodeInFlight) {
            self.needsFreshSourceFrame = YES;
            self.overloadDropCount += 1;
            if (transportInfo.groupIndex == 0) {
                self.overloadSourceFrameCount += 1;
            }
            if (transportInfo.groupIndex == 0 && self.overloadSourceFrameCount % 30 == 1) {
                NSLog(@"[CNMoonlightPyroWaveDecoder] Dropping stale PWF2 source images while decode is in flight (images=%lu groups=%lu)",
                      (unsigned long)self.overloadSourceFrameCount,
                      (unsigned long)self.overloadDropCount);
            }
        } else if (self.needsFreshSourceFrame && transportInfo.groupIndex != 0) {
            // The rest of this source image is stale. Waiting for its first
            // transport group is cheaper than generating UI work per packet.
        } else {
            if (self.needsFreshSourceFrame) {
                self.decoderClear(self.decoder);
                self.needsFreshSourceFrame = NO;
                self.hasPendingSourceFrame = NO;
            }

            BOOL startsNewSourceFrame = transportInfo.groupIndex == 0;
            if ((!self.hasPendingSourceFrame && !startsNewSourceFrame)
                || (self.hasPendingSourceFrame
                    && (transportInfo.sourceFrame != self.activeSourceFrame
                        || transportInfo.groupIndex != self.nextSourceGroupIndex)
                    && !startsNewSourceFrame)) {
                self.decoderClear(self.decoder);
                self.hasPendingSourceFrame = NO;
                self.needsFreshSourceFrame = YES;
            } else {
                if (startsNewSourceFrame) {
                    if (self.hasPendingSourceFrame) {
                        self.decoderClear(self.decoder);
                    }
                    self.activeSourceFrame = transportInfo.sourceFrame;
                    self.activeSourceGroupCount = transportInfo.groupCount;
                    self.nextSourceGroupIndex = 0;
                    self.hasPendingSourceFrame = YES;
                }

                self.pushedPacketCount += 1;
                NSUInteger logicalPacketCount = 0;
                pyrowave_result result = [self pushPacketizedData:frameData logicalPacketCount:&logicalPacketCount];
                if (result != PYROWAVE_SUCCESS) {
                    self.decoderClear(self.decoder);
                    self.hasPendingSourceFrame = NO;
                    immediateError = [NSString stringWithFormat:@"pyrowave_decoder_push_packet failed: %d", (int)result];
                } else {
                    self.nextSourceGroupIndex = transportInfo.groupIndex + 1;
                    BOOL isLastSourceGroup = self.nextSourceGroupIndex == self.activeSourceGroupCount;
                    if (isLastSourceGroup && self.decoderDecodeIsReady(self.decoder, false)) {
                        self.hasPendingSourceFrame = NO;
                        shouldDecode = YES;
                        self.decodeInFlight = YES;
                    }
                }
            }
        }
    }

    if (immediateError) {
        completion(nil, NULL, immediateError);
        return;
    }
    if (!shouldDecode) {
        return;
    }

    dispatch_async(self.decodeQueue, ^{
        NSString *decodeError = nil;
        CNPyroWaveGPUFrame *GPUFrame = nil;
        CMSampleBufferRef sampleBuffer = NULL;
        if (self.isGPUPathAvailable) {
            GPUFrame = [self copyReadyGPUFrameWithError:&decodeError];
        } else {
            sampleBuffer = [self copyReadySampleBufferWithRtpTimestamp:rtpTimestamp
                                                    presentationTimeUs:presentationTimeUs
                                                                 error:&decodeError];
        }
        @synchronized (self) {
            if (self.needsFreshSourceFrame) {
                self.decoderClear(self.decoder);
            }
            self.decodeInFlight = NO;
        }
        completion(GPUFrame, sampleBuffer, decodeError);
    });
}

- (void)submitSteamPacket:(NSData *)packet
              completion:(void (^)(CNPyroWaveGPUFrame *, NSString *))completion {
    // Steam supplies codec packets directly, without the PWF2 envelope used
    // by the other transport. Keep accumulation and GPU submission ordered.
    @synchronized (self) {
        if (self.steamCancelled || packet.length > 4 * 1024 * 1024 - self.steamPendingBytes) return;
        self.steamPendingBytes += packet.length;
    }
    dispatch_async(self.decodeQueue, ^{
        @autoreleasepool {
            @try {
            @synchronized (self) { if (self.steamCancelled) return; }
            if (!self.isGPUPathAvailable) {
                completion(nil, self.statusMessage);
                return;
            }
            pyrowave_result result = self.decoderPushPacket(self.decoder, packet.bytes, packet.length);
            if (result != PYROWAVE_SUCCESS) {
                self.decoderClear(self.decoder);
                self.steamRejectedPackets += 1;
                CFTimeInterval now = CACurrentMediaTime();
                if (now - self.steamLastErrorTime >= 1) {
                    self.steamLastErrorTime = now;
                    const uint8_t *bytes = packet.bytes;
                    NSMutableString *prefix = [NSMutableString string];
                    for (NSUInteger index = 0; index < MIN(packet.length, 32); index++) [prefix appendFormat:@"%02x", bytes[index]];
                    completion(nil, [NSString stringWithFormat:@"Steam PyroWave rejected %lu packets; latest %d, %lu bytes, header %@", (unsigned long)self.steamRejectedPackets, result, (unsigned long)packet.length, prefix]);
                }
                return;
            }
            if (self.decoderDecodeIsReady(self.decoder, false)) {
                NSString *error = nil;
                CNPyroWaveGPUFrame *frame = [self copyReadyGPUFrameWithError:&error];
                @synchronized (self) {
                    if (self.steamCancelled) {
                        [frame markPresentationCompleteAtTime:CACurrentMediaTime()];
                        return;
                    }
                }
                completion(frame, error);
            }
            } @finally {
                @synchronized (self) { self.steamPendingBytes -= packet.length; }
            }
        }
    });
}

- (void)cancelSteamPackets {
    @synchronized (self) { self.steamCancelled = YES; }
}

- (nullable CNPyroWaveGPUFrame *)copyReadyGPUFrameWithError:(NSString **)error {
    __block NSUInteger selectedSlot = NSNotFound;
    @synchronized (self) {
        for (NSUInteger slot = 0; slot < CNPyroWaveGPUFrameRingSize; slot++) {
            if (!self.GPUResourceSlots[slot].inUse) {
                selectedSlot = slot;
                self.GPUResourceSlots[slot].inUse = true;
                self.GPUInFlightCount += 1;
                break;
            }
        }
        if (selectedSlot == NSNotFound) self.GPUFrameDropCount += 1;
    }
    if (selectedSlot == NSNotFound) {
        self.decoderClear(self.decoder);
        if (self.GPUFrameDropCount % 60 == 1) {
            NSLog(@"[CNMoonlightPyroWaveDecoder] GPU ring full; dropping newest frame (inFlight=%lu drops=%lu)",
                  (unsigned long)self.GPUInFlightCount, (unsigned long)self.GPUFrameDropCount);
        }
        if (error) *error = @"PyroWave GPU frame ring is full";
        return nil;
    }

    uint64_t sequence = ++self.nextGPUSequenceNumber;
    CNPyroWaveGPUResourceSlot *slot = &self.GPUResourceSlots[selectedSlot];
    slot->sequenceNumber = sequence;
    CNPyroWaveGPUFrame *frame = self.GPUFrames[selectedSlot];
    frame.sequenceNumber = sequence;
    frame.presentationCompleted = NO;

    pyrowave_gpu_buffers buffers = {};
    for (NSUInteger plane = 0; plane < 3; plane++) {
        buffers.planes[plane].image = slot->images[plane];
        buffers.planes[plane].width = plane == 0 ? (uint32_t)self.width : (uint32_t)self.width / 2;
        buffers.planes[plane].height = plane == 0 ? (uint32_t)self.height : (uint32_t)self.height / 2;
        buffers.planes[plane].image_format = CNVK_FORMAT_R8_UNORM;
        buffers.planes[plane].view_format = CNVK_FORMAT_R8_UNORM;
        buffers.planes[plane].aspect = CNVK_IMAGE_ASPECT_COLOR_BIT;
        buffers.planes[plane].swizzle = 0;
        buffers.planes[plane].layout = CNVK_IMAGE_LAYOUT_GENERAL;
    }

    CFTimeInterval submittedAt = CACurrentMediaTime();
    CNVkCommandBuffer commandBuffer = slot->decodeCommandBuffer;
    CNVkResult vkResult = self.vkResetCommandBuffer(commandBuffer, 0);
    CNVkCommandBufferBeginInfo beginInfo = {};
    beginInfo.sType = CNVK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    beginInfo.flags = CNVK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    if (vkResult == CNVK_SUCCESS) {
        vkResult = self.vkBeginCommandBuffer(commandBuffer, &beginInfo);
    }

    pyrowave_result result = PYROWAVE_ERROR_GENERIC;
    if (vkResult == CNVK_SUCCESS) {
        // Let Granite own and retire its upload command buffer. A binary
        // semaphore makes the otherwise deferred submission explicit and is
        // consumed by our small Vulkan-to-Metal visibility submission below.
        CNPyroWaveGPUSyncOperation release = {};
        release.sync.semaphore = slot->decodeCompleteSemaphore;
        result = self.decoderDecodeGPUBuffer(self.decoder, NULL, &release, &buffers);
    }

    if (vkResult == CNVK_SUCCESS && result == PYROWAVE_SUCCESS) {
        CNVkImageMemoryBarrier barriers[3] = {};
        for (NSUInteger plane = 0; plane < 3; plane++) {
            barriers[plane].sType = CNVK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
            barriers[plane].srcAccessMask = CNVK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
            barriers[plane].dstAccessMask = CNVK_ACCESS_SHADER_READ_BIT;
            barriers[plane].oldLayout = CNVK_IMAGE_LAYOUT_GENERAL;
            barriers[plane].newLayout = CNVK_IMAGE_LAYOUT_GENERAL;
            barriers[plane].srcQueueFamilyIndex = CNVK_QUEUE_FAMILY_IGNORED;
            barriers[plane].dstQueueFamilyIndex = CNVK_QUEUE_FAMILY_IGNORED;
            barriers[plane].image = slot->images[plane];
            barriers[plane].subresourceRange = (CNVkImageSubresourceRange){ CNVK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
        }
        self.vkCmdPipelineBarrier(commandBuffer,
                                  CNVK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                                  CNVK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                                  0, 0, NULL, 0, NULL, 3, barriers);
        vkResult = self.vkEndCommandBuffer(commandBuffer);
    }
    if (vkResult == CNVK_SUCCESS && result == PYROWAVE_SUCCESS) {
        CNVkSubmitInfo submit = {};
        submit.sType = CNVK_STRUCTURE_TYPE_SUBMIT_INFO;
        CNVkFlags waitStage = CNVK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        submit.waitSemaphoreCount = 1;
        submit.pWaitSemaphores = &slot->decodeCompleteSemaphore;
        submit.pWaitDstStageMask = &waitStage;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &commandBuffer;
        vkResult = self.vkQueueSubmit(self.vkQueue, 1, &submit, NULL);
    }
    if (vkResult == CNVK_SUCCESS && result == PYROWAVE_SUCCESS) {
        // The compressed payload has been copied into Granite's owned staging
        // allocation during command recording and can now be discarded.
        self.decoderClear(self.decoder);
    }
    CFTimeInterval returnedAt = CACurrentMediaTime();
    self.GPUSubmissionDurationTotal += returnedAt - submittedAt;
    if (result != PYROWAVE_SUCCESS || vkResult != CNVK_SUCCESS) {
        @synchronized (self) {
            slot->inUse = false;
            self.GPUInFlightCount -= 1;
        }
        self.decoderClear(self.decoder);
        if (error) {
            *error = result != PYROWAVE_SUCCESS
                ? [NSString stringWithFormat:@"pyrowave_decoder_decode_gpu_buffer failed: %d%@",
                   result, [self formattedLastPyroWaveError]]
                : [NSString stringWithFormat:@"PyroWave Vulkan decode submission failed: %d", vkResult];
        }
        return nil;
    }

    self.GPUDecodedFrameCount += 1;
    frame.decodeSubmittedTime = submittedAt;
    __weak typeof(self) weakSelf = self;
    frame.presentationCompletion = ^(NSUInteger completedSlot, uint64_t completedSequence, CFTimeInterval completionTime) {
        CNMoonlightPyroWaveDecoder *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.GPUResourceSlots) return;
        BOOL shouldLog = NO;
        NSUInteger submittedCount = 0;
        NSUInteger completedCount = 0;
        NSUInteger inFlightCount = 0;
        NSUInteger dropCount = 0;
        CFTimeInterval submissionDurationTotal = 0;
        CFTimeInterval completionDurationTotal = 0;
        @synchronized (strongSelf) {
            CNPyroWaveGPUResourceSlot *completed = &strongSelf.GPUResourceSlots[completedSlot];
            if (completed->inUse && completed->sequenceNumber == completedSequence) {
                completed->inUse = false;
                strongSelf.GPUInFlightCount -= 1;
                strongSelf.GPUCompletedFrameCount += 1;
                strongSelf.GPUFrameDurationTotal += completionTime - submittedAt;
                shouldLog = strongSelf.GPUCompletedFrameCount % 600 == 0;
                submittedCount = strongSelf.GPUDecodedFrameCount;
                completedCount = strongSelf.GPUCompletedFrameCount;
                inFlightCount = strongSelf.GPUInFlightCount;
                dropCount = strongSelf.GPUFrameDropCount;
                submissionDurationTotal = strongSelf.GPUSubmissionDurationTotal;
                completionDurationTotal = strongSelf.GPUFrameDurationTotal;
            }
        }
        if (shouldLog) {
            NSLog(@"[CNMoonlightPyroWaveDecoder] GPU perf submitted=%lu completed=%lu submit=%.2fms complete=%.2fms inFlight=%lu drops=%lu",
                  (unsigned long)submittedCount,
                  (unsigned long)completedCount,
                  submissionDurationTotal * 1000.0 / MAX(submittedCount, 1),
                  completionDurationTotal * 1000.0 / MAX(completedCount, 1),
                  (unsigned long)inFlightCount,
                  (unsigned long)dropCount);
        }
    };
    return frame;
}

- (nullable CMSampleBufferRef)copySampleBufferForDecodeUnit:(PDECODE_UNIT)decodeUnit
                                                      error:(NSString *_Nullable *_Nullable)error {
    if (!self.available || !decodeUnit) {
        if (error) {
            *error = self.statusMessage;
        }
        return NULL;
    }

    NSData *frameData = [self packetizedDataForDecodeUnit:decodeUnit];
    if (frameData.length == 0) {
        if (error) {
            *error = @"PyroWave decode unit had no picture data";
        }
        return NULL;
    }

    self.pushedPacketCount += 1;
    if (self.pushedPacketCount <= 5) {
        NSLog(@"[CNMoonlightPyroWaveDecoder] packet #%lu rtp=%u frameType=%d fullLength=%d picData=%lu hash=%016llx",
              (unsigned long)self.pushedPacketCount,
              decodeUnit->rtpTimestamp,
              decodeUnit->frameType,
              decodeUnit->fullLength,
              (unsigned long)frameData.length,
              CNPyroWavePacketHash(frameData));
    }

    NSUInteger logicalPacketCount = 0;
    pyrowave_result result = [self pushPacketizedData:frameData logicalPacketCount:&logicalPacketCount];
    if (result != PYROWAVE_SUCCESS) {
        self.decoderClear(self.decoder);
        if (self.failureLogCount < 10) {
            self.failureLogCount += 1;
            NSLog(@"[CNMoonlightPyroWaveDecoder] pyrowave_decoder_push_packet failed result=%d packetBytes=%lu",
                  (int)result,
                  (unsigned long)frameData.length);
        }
        if (error) {
            *error = [NSString stringWithFormat:@"pyrowave_decoder_push_packet failed: %d", (int)result];
        }
        return NULL;
    }

    if (self.pushedPacketCount <= 5 && logicalPacketCount > 1) {
        NSLog(@"[CNMoonlightPyroWaveDecoder] unpacked PyroWave frame into %lu logical packets",
              (unsigned long)logicalPacketCount);
    }

    bool ready = self.decoderDecodeIsReady(self.decoder, false);
    if (!ready) {
        if (self.waitingPacketLogCount < 10) {
            self.waitingPacketLogCount += 1;
            NSLog(@"[CNMoonlightPyroWaveDecoder] accumulating PyroWave packets after packet #%lu rtp=%u bytes=%lu",
                  (unsigned long)self.pushedPacketCount,
                  decodeUnit->rtpTimestamp,
                  (unsigned long)frameData.length);
        }
        if (error) {
            *error = @"PyroWave decoder is accumulating packets";
        }
        return NULL;
    }

    return [self copyReadySampleBufferWithRtpTimestamp:decodeUnit->rtpTimestamp
                                     presentationTimeUs:decodeUnit->presentationTimeUs
                                                  error:error];
}

- (nullable CMSampleBufferRef)copyReadySampleBufferWithRtpTimestamp:(uint32_t)rtpTimestamp
                                                   presentationTimeUs:(int64_t)presentationTimeUs
                                                                error:(NSString *_Nullable *_Nullable)error {
    CVPixelBufferRef pixelBuffer = NULL;
    NSDictionary *auxiliaryAttributes = @{
        (NSString *)kCVPixelBufferPoolAllocationThresholdKey: @12
    };
    CVReturn cvStatus = self.pixelBufferPool
        ? CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
              kCFAllocatorDefault,
              self.pixelBufferPool,
              (__bridge CFDictionaryRef)auxiliaryAttributes,
              &pixelBuffer
          )
        : kCVReturnAllocationFailed;
    if (cvStatus != kCVReturnSuccess || !pixelBuffer) {
        self.decoderClear(self.decoder);
        self.pixelBufferPoolExhaustionCount += 1;
        if (self.pixelBufferPoolExhaustionCount % 60 == 1) {
            NSLog(@"[CNMoonlightPyroWaveDecoder] Output pixel buffer pool is full; dropping newest decoded frame (drops=%lu, status=%d)",
                  (unsigned long)self.pixelBufferPoolExhaustionCount,
                  cvStatus);
        }
        if (error) {
            *error = @"PyroWave output pixel buffer pool is full";
        }
        return NULL;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    if (CVPixelBufferGetPlaneCount(pixelBuffer) != 3) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CVPixelBufferRelease(pixelBuffer);
        self.decoderClear(self.decoder);
        if (error) {
            *error = @"PyroWave output pixel buffer does not have three planes";
        }
        return NULL;
    }

    pyrowave_cpu_buffer output = {};
    for (size_t plane = 0; plane < 3; plane++) {
        output.data[plane] = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane);
        output.row_stride_in_bytes[plane] = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane);
        output.plane_size_in_bytes[plane] = output.row_stride_in_bytes[plane]
            * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane);
    }
    output.width = self.width;
    output.height = self.height;
    output.format = PYROWAVE_CPU_BUFFER_FORMAT_YUV420P;

    CFTimeInterval decodeStarted = CACurrentMediaTime();
    pyrowave_result result = self.decoderDecodeCPUBufferSynchronous(self.decoder, &output);
    CFTimeInterval decodeFinished = CACurrentMediaTime();
    if (result != PYROWAVE_SUCCESS) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CVPixelBufferRelease(pixelBuffer);
        self.decoderClear(self.decoder);
        if (self.failureLogCount < 10) {
            self.failureLogCount += 1;
            NSLog(@"[CNMoonlightPyroWaveDecoder] pyrowave_decoder_decode_cpu_buffer_synchronous failed result=%d",
                  (int)result);
        }
        if (error) {
            *error = [NSString stringWithFormat:@"pyrowave_decoder_decode_cpu_buffer_synchronous failed: %d", (int)result];
        }
        return NULL;
    }

    self.decodedFrameCount += 1;
    if (self.decodedFrameCount <= 5) {
        uint8_t minY = 0, maxY = 0, minU = 0, maxU = 0, minV = 0, maxV = 0;
        uint64_t avgY = 0, avgU = 0, avgV = 0;
        CNPlaneStats(output.data[0], output.plane_size_in_bytes[0], &minY, &maxY, &avgY);
        CNPlaneStats(output.data[1], output.plane_size_in_bytes[1], &minU, &maxU, &avgU);
        CNPlaneStats(output.data[2], output.plane_size_in_bytes[2], &minV, &maxV, &avgV);
        NSLog(@"[CNMoonlightPyroWaveDecoder] decoded frame #%lu y=%u..%u/%llu u=%u..%u/%llu v=%u..%u/%llu",
              (unsigned long)self.decodedFrameCount,
              minY,
              maxY,
              avgY,
              minU,
              maxU,
              avgU,
              minV,
              maxV,
              avgV);
    }

    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    CMSampleBufferRef sampleBuffer = [self copySampleBufferFromPixelBuffer:pixelBuffer
                                                           rtpTimestamp:rtpTimestamp
                                                    presentationTimeUs:presentationTimeUs];
    CVPixelBufferRelease(pixelBuffer);
    CFTimeInterval outputFinished = CACurrentMediaTime();
    self.decodeDurationTotal += decodeFinished - decodeStarted;
    self.outputDurationTotal += outputFinished - decodeFinished;
    if (self.decodedFrameCount % 60 == 0) {
        NSLog(@"[CNMoonlightPyroWaveDecoder] perf frames=%lu decode=%.2fms output=%.2fms total=%.2fms",
              (unsigned long)self.decodedFrameCount,
              self.decodeDurationTotal * 1000.0 / self.decodedFrameCount,
              self.outputDurationTotal * 1000.0 / self.decodedFrameCount,
              (self.decodeDurationTotal + self.outputDurationTotal) * 1000.0 / self.decodedFrameCount);
    }
    if (!sampleBuffer) {
        if (self.failureLogCount < 10) {
            self.failureLogCount += 1;
            NSLog(@"[CNMoonlightPyroWaveDecoder] Failed to create sample buffer from direct PyroWave output");
        }
        if (error) {
            *error = @"Failed to create sample buffer from direct PyroWave output";
        }
    }
    return sampleBuffer;
}

- (pyrowave_result)pushPacketizedData:(NSData *)frameData logicalPacketCount:(NSUInteger *)logicalPacketCount {
    const uint8_t *bytes = frameData.bytes;
    NSUInteger length = frameData.length;
    if (!bytes || length == 0) {
        return PYROWAVE_ERROR_INVALID_ARGUMENT;
    }

    CNPyroWaveTransportInfo transportInfo = {};
    if (!CNPyroWaveReadTransportInfo(bytes, length, &transportInfo)) {
        if (logicalPacketCount) {
            *logicalPacketCount = 1;
        }
        return self.decoderPushPacket(self.decoder, bytes, length);
    }

    NSUInteger offset = transportInfo.headerLength;
    NSUInteger packetCount = 0;
    while (offset < length) {
        if (length - offset < 4) {
            return PYROWAVE_ERROR_INVALID_ARGUMENT;
        }

        uint32_t packetLength = ((uint32_t)bytes[offset] << 24)
            | ((uint32_t)bytes[offset + 1] << 16)
            | ((uint32_t)bytes[offset + 2] << 8)
            | (uint32_t)bytes[offset + 3];
        offset += 4;
        if (packetLength == 0 || packetLength > length - offset) {
            return PYROWAVE_ERROR_INVALID_ARGUMENT;
        }

        pyrowave_result result = self.decoderPushPacket(self.decoder, bytes + offset, packetLength);
        if (result != PYROWAVE_SUCCESS) {
            return result;
        }

        offset += packetLength;
        packetCount += 1;
    }

    if (packetCount == 0) {
        return PYROWAVE_ERROR_INVALID_ARGUMENT;
    }
    if (logicalPacketCount) {
        *logicalPacketCount = packetCount;
    }
    return PYROWAVE_SUCCESS;
}

- (NSData *)packetizedDataForDecodeUnit:(PDECODE_UNIT)decodeUnit {
    [self.frameBuffer setLength:(NSUInteger)MAX(decodeUnit->fullLength, 0)];
    uint8_t *dst = self.frameBuffer.mutableBytes;
    NSUInteger offset = 0;

    for (PLENTRY entry = decodeUnit->bufferList; entry != NULL; entry = entry->next) {
        if (entry->bufferType != BUFFER_TYPE_PICDATA || entry->length <= 0) {
            continue;
        }

        NSUInteger length = (NSUInteger)entry->length;
        if (offset + length > self.frameBuffer.length) {
            [self.frameBuffer increaseLengthBy:offset + length - self.frameBuffer.length];
            dst = self.frameBuffer.mutableBytes;
        }

        memcpy(dst + offset, entry->data, length);
        offset += length;
    }

    [self.frameBuffer setLength:offset];
    return self.frameBuffer;
}

- (nullable CMSampleBufferRef)copySampleBufferFromPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                                  rtpTimestamp:(uint32_t)rtpTimestamp
                                           presentationTimeUs:(int64_t)presentationTimeUs {
    if (!self.outputFormatDescription) {
        return NULL;
    }

    CMTime presentationTime = presentationTimeUs > 0
        ? CMTimeMake(presentationTimeUs, 1000000)
        : CMTimeMake((int64_t)rtpTimestamp, 90000);
    CMSampleTimingInfo timing = {
        kCMTimeInvalid,
        presentationTime,
        kCMTimeInvalid
    };

    CMSampleBufferRef sampleBuffer = NULL;
    OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(
        kCFAllocatorDefault,
        pixelBuffer,
        self.outputFormatDescription,
        &timing,
        &sampleBuffer
    );

    return status == noErr ? sampleBuffer : NULL;
}

@end
