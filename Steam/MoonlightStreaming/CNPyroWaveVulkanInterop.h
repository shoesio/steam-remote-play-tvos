#ifndef CNPyroWaveVulkanInterop_h
#define CNPyroWaveVulkanInterop_h

#include <stdint.h>

// Minimal Vulkan ABI used by the dynamically loaded MoltenVK interop path.
// Keeping this private avoids making the app target depend on a Vulkan SDK.
typedef uint32_t CNVkFlags;
typedef uint32_t CNVkBool32;
typedef uint64_t CNVkDeviceSize;
typedef int32_t CNVkResult;
typedef int32_t CNVkStructureType;
typedef int32_t CNVkFormat;
typedef int32_t CNVkImageType;
typedef int32_t CNVkImageTiling;
typedef int32_t CNVkSharingMode;
typedef int32_t CNVkImageLayout;
typedef int32_t CNVkCommandBufferLevel;

typedef struct CNVkInstance_T *CNVkInstance;
typedef struct CNVkPhysicalDevice_T *CNVkPhysicalDevice;
typedef struct CNVkDevice_T *CNVkDevice;
typedef struct CNVkQueue_T *CNVkQueue;
typedef struct CNVkImage_T *CNVkImage;
typedef struct CNVkDeviceMemory_T *CNVkDeviceMemory;
typedef struct CNVkCommandPool_T *CNVkCommandPool;
typedef struct CNVkCommandBuffer_T *CNVkCommandBuffer;
typedef struct CNVkFence_T *CNVkFence;
typedef struct CNVkSemaphore_T *CNVkSemaphore;

enum {
    CNVK_SUCCESS = 0,
    CNVK_STRUCTURE_TYPE_SUBMIT_INFO = 4,
    CNVK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO = 5,
    CNVK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO = 9,
    CNVK_STRUCTURE_TYPE_IMAGE_CREATE_INFO = 14,
    CNVK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO = 39,
    CNVK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO = 40,
    CNVK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO = 42,
    CNVK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER = 45,
    CNVK_FORMAT_R8_UNORM = 9,
    CNVK_IMAGE_TYPE_2D = 1,
    CNVK_IMAGE_TILING_OPTIMAL = 0,
    CNVK_SHARING_MODE_EXCLUSIVE = 0,
    CNVK_IMAGE_LAYOUT_UNDEFINED = 0,
    CNVK_IMAGE_LAYOUT_GENERAL = 1,
    CNVK_SAMPLE_COUNT_1_BIT = 0x1,
    CNVK_IMAGE_USAGE_SAMPLED_BIT = 0x4,
    CNVK_IMAGE_USAGE_STORAGE_BIT = 0x8,
    CNVK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT = 0x10,
    CNVK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT = 0x1,
    CNVK_QUEUE_GRAPHICS_BIT = 0x1,
    CNVK_PIPELINE_STAGE_TOP_OF_PIPE_BIT = 0x1,
    CNVK_PIPELINE_STAGE_ALL_COMMANDS_BIT = 0x10000,
    CNVK_ACCESS_SHADER_READ_BIT = 0x20,
    CNVK_ACCESS_SHADER_WRITE_BIT = 0x40,
    CNVK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT = 0x100,
    CNVK_IMAGE_ASPECT_COLOR_BIT = 0x1,
    CNVK_COMMAND_BUFFER_LEVEL_PRIMARY = 0,
    CNVK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT = 0x1,
    CNVK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT = 0x2,
    CNVK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT = 0x80,
    CNVK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT = 0x400,
    CNVK_QUEUE_FAMILY_IGNORED = 0xffffffffu
};

typedef struct CNVkExtent3D {
    uint32_t width;
    uint32_t height;
    uint32_t depth;
} CNVkExtent3D;

typedef struct CNVkImageCreateInfo {
    CNVkStructureType sType;
    const void *pNext;
    CNVkFlags flags;
    CNVkImageType imageType;
    CNVkFormat format;
    CNVkExtent3D extent;
    uint32_t mipLevels;
    uint32_t arrayLayers;
    CNVkFlags samples;
    CNVkImageTiling tiling;
    CNVkFlags usage;
    CNVkSharingMode sharingMode;
    uint32_t queueFamilyIndexCount;
    const uint32_t *pQueueFamilyIndices;
    CNVkImageLayout initialLayout;
} CNVkImageCreateInfo;

typedef struct CNVkMemoryRequirements {
    CNVkDeviceSize size;
    CNVkDeviceSize alignment;
    uint32_t memoryTypeBits;
} CNVkMemoryRequirements;

typedef struct CNVkMemoryAllocateInfo {
    CNVkStructureType sType;
    const void *pNext;
    CNVkDeviceSize allocationSize;
    uint32_t memoryTypeIndex;
} CNVkMemoryAllocateInfo;

typedef struct CNVkMemoryType {
    CNVkFlags propertyFlags;
    uint32_t heapIndex;
} CNVkMemoryType;

typedef struct CNVkMemoryHeap {
    CNVkDeviceSize size;
    CNVkFlags flags;
} CNVkMemoryHeap;

typedef struct CNVkPhysicalDeviceMemoryProperties {
    uint32_t memoryTypeCount;
    CNVkMemoryType memoryTypes[32];
    uint32_t memoryHeapCount;
    CNVkMemoryHeap memoryHeaps[16];
} CNVkPhysicalDeviceMemoryProperties;

typedef struct CNVkQueueFamilyProperties {
    CNVkFlags queueFlags;
    uint32_t queueCount;
    uint32_t timestampValidBits;
    CNVkExtent3D minImageTransferGranularity;
} CNVkQueueFamilyProperties;

typedef struct CNVkCommandPoolCreateInfo {
    CNVkStructureType sType;
    const void *pNext;
    CNVkFlags flags;
    uint32_t queueFamilyIndex;
} CNVkCommandPoolCreateInfo;

typedef struct CNVkSemaphoreCreateInfo {
    CNVkStructureType sType;
    const void *pNext;
    CNVkFlags flags;
} CNVkSemaphoreCreateInfo;

typedef struct CNVkCommandBufferAllocateInfo {
    CNVkStructureType sType;
    const void *pNext;
    CNVkCommandPool commandPool;
    CNVkCommandBufferLevel level;
    uint32_t commandBufferCount;
} CNVkCommandBufferAllocateInfo;

typedef struct CNVkCommandBufferBeginInfo {
    CNVkStructureType sType;
    const void *pNext;
    CNVkFlags flags;
    const void *pInheritanceInfo;
} CNVkCommandBufferBeginInfo;

typedef struct CNVkImageSubresourceRange {
    CNVkFlags aspectMask;
    uint32_t baseMipLevel;
    uint32_t levelCount;
    uint32_t baseArrayLayer;
    uint32_t layerCount;
} CNVkImageSubresourceRange;

typedef struct CNVkImageMemoryBarrier {
    CNVkStructureType sType;
    const void *pNext;
    CNVkFlags srcAccessMask;
    CNVkFlags dstAccessMask;
    CNVkImageLayout oldLayout;
    CNVkImageLayout newLayout;
    uint32_t srcQueueFamilyIndex;
    uint32_t dstQueueFamilyIndex;
    CNVkImage image;
    CNVkImageSubresourceRange subresourceRange;
} CNVkImageMemoryBarrier;

typedef struct CNVkSubmitInfo {
    CNVkStructureType sType;
    const void *pNext;
    uint32_t waitSemaphoreCount;
    const CNVkSemaphore *pWaitSemaphores;
    const CNVkFlags *pWaitDstStageMask;
    uint32_t commandBufferCount;
    const CNVkCommandBuffer *pCommandBuffers;
    uint32_t signalSemaphoreCount;
    const CNVkSemaphore *pSignalSemaphores;
} CNVkSubmitInfo;

typedef CNVkResult (*CNPFN_vkCreateImage)(CNVkDevice, const CNVkImageCreateInfo *, const void *, CNVkImage *);
typedef void (*CNPFN_vkDestroyImage)(CNVkDevice, CNVkImage, const void *);
typedef void (*CNPFN_vkGetImageMemoryRequirements)(CNVkDevice, CNVkImage, CNVkMemoryRequirements *);
typedef CNVkResult (*CNPFN_vkAllocateMemory)(CNVkDevice, const CNVkMemoryAllocateInfo *, const void *, CNVkDeviceMemory *);
typedef void (*CNPFN_vkFreeMemory)(CNVkDevice, CNVkDeviceMemory, const void *);
typedef CNVkResult (*CNPFN_vkBindImageMemory)(CNVkDevice, CNVkImage, CNVkDeviceMemory, CNVkDeviceSize);
typedef void (*CNPFN_vkGetPhysicalDeviceMemoryProperties)(CNVkPhysicalDevice, CNVkPhysicalDeviceMemoryProperties *);
typedef void (*CNPFN_vkGetPhysicalDeviceQueueFamilyProperties)(CNVkPhysicalDevice, uint32_t *, CNVkQueueFamilyProperties *);
typedef void (*CNPFN_vkGetDeviceQueue)(CNVkDevice, uint32_t, uint32_t, CNVkQueue *);
typedef CNVkResult (*CNPFN_vkCreateCommandPool)(CNVkDevice, const CNVkCommandPoolCreateInfo *, const void *, CNVkCommandPool *);
typedef void (*CNPFN_vkDestroyCommandPool)(CNVkDevice, CNVkCommandPool, const void *);
typedef CNVkResult (*CNPFN_vkAllocateCommandBuffers)(CNVkDevice, const CNVkCommandBufferAllocateInfo *, CNVkCommandBuffer *);
typedef CNVkResult (*CNPFN_vkResetCommandBuffer)(CNVkCommandBuffer, CNVkFlags);
typedef CNVkResult (*CNPFN_vkBeginCommandBuffer)(CNVkCommandBuffer, const CNVkCommandBufferBeginInfo *);
typedef CNVkResult (*CNPFN_vkEndCommandBuffer)(CNVkCommandBuffer);
typedef void (*CNPFN_vkCmdPipelineBarrier)(CNVkCommandBuffer, CNVkFlags, CNVkFlags, CNVkFlags, uint32_t, const void *, uint32_t, const void *, uint32_t, const CNVkImageMemoryBarrier *);
typedef CNVkResult (*CNPFN_vkQueueSubmit)(CNVkQueue, uint32_t, const CNVkSubmitInfo *, CNVkFence);
typedef CNVkResult (*CNPFN_vkQueueWaitIdle)(CNVkQueue);
typedef CNVkResult (*CNPFN_vkCreateSemaphore)(CNVkDevice, const CNVkSemaphoreCreateInfo *, const void *, CNVkSemaphore *);
typedef void (*CNPFN_vkDestroySemaphore)(CNVkDevice, CNVkSemaphore, const void *);

#endif
