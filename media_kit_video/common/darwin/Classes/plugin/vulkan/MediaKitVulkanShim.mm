// MediaKitVulkanShim.mm
//
// MoltenVK-backed Vulkan device + Metal interop, behind a plain C interface
// (see MediaKitVulkanShim.h). Compiled for both macOS and iOS via the
// media_kit_video podspec.
//
// Required link-time deps (configured by the consumer's podspec):
//   - libMoltenVK.dylib (or libvulkan.dylib loader pointing to MoltenVK)
//   - Metal.framework / QuartzCore.framework (for MTLTexture / MTLDevice)
//   - Foundation.framework
//
// Required Vulkan extensions:
//   instance: VK_KHR_get_physical_device_properties2,
//             VK_EXT_metal_surface (present but unused here),
//             VK_KHR_portability_enumeration (MoltenVK is non-conformant)
//   device:   VK_KHR_portability_subset (mandatory on MoltenVK),
//             VK_KHR_swapchain (libplacebo asks for it),
//             VK_EXT_metal_objects (MTLTexture import),
//             VK_KHR_external_memory,
//             VK_KHR_synchronization2 (libplacebo prefers timeline; binary OK).
//
// All Vulkan symbols are loaded dynamically through vkGetInstanceProcAddr to
// avoid a hard link dependency on the loader's import library; only the
// loader entry point itself is statically referenced through dlsym.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dlfcn.h>

#define VK_NO_PROTOTYPES 1
#define VK_USE_PLATFORM_METAL_EXT 1
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_metal.h>

#include "MediaKitVulkanShim.h"

#include <mutex>
#include <vector>

namespace {

#define MK_VK_LOG(fmt, ...) \
    NSLog(@"[MediaKitVulkan] " fmt, ##__VA_ARGS__)

#define MK_VK_REQUIRE(call_)                                                    \
    do {                                                                        \
        VkResult _rc = (call_);                                                 \
        if (_rc != VK_SUCCESS) {                                                \
            MK_VK_LOG(@"%s failed: %d", #call_, _rc);                           \
            return nullptr;                                                     \
        }                                                                       \
    } while (0)

PFN_vkGetInstanceProcAddr resolve_loader() {
    // Try the system loader (libvulkan.dylib) first; fall back to libMoltenVK
    // shipped alongside the host bundle.
    static const char *candidates[] = {
        "libvulkan.dylib",
        "libvulkan.1.dylib",
        "libMoltenVK.dylib",
        nullptr,
    };
    for (int i = 0; candidates[i]; i++) {
        void *handle = dlopen(candidates[i], RTLD_LAZY | RTLD_LOCAL);
        if (!handle)
            continue;
        auto fn = reinterpret_cast<PFN_vkGetInstanceProcAddr>(
            dlsym(handle, "vkGetInstanceProcAddr"));
        if (fn) {
            MK_VK_LOG(@"Loaded Vulkan loader from %s", candidates[i]);
            return fn;
        }
        dlclose(handle);
    }
    MK_VK_LOG(@"No Vulkan loader found (tried libvulkan / libMoltenVK).");
    return nullptr;
}

} // namespace

struct MKVulkanContext {
    PFN_vkGetInstanceProcAddr  gipa = nullptr;

    VkInstance       instance = VK_NULL_HANDLE;
    VkPhysicalDevice phys     = VK_NULL_HANDLE;
    VkDevice         device   = VK_NULL_HANDLE;
    uint32_t         qf_index = 0;
    uint32_t         qf_count = 1;
    VkQueue          queue    = VK_NULL_HANDLE;
    VkCommandPool    pool     = VK_NULL_HANDLE;

    VkPhysicalDeviceFeatures2 features2{};

    std::vector<const char *> dev_exts;
    std::mutex                queue_mutex;

#define VK_FN(name) PFN_##name name = nullptr
    VK_FN(vkCreateInstance);
    VK_FN(vkDestroyInstance);
    VK_FN(vkEnumeratePhysicalDevices);
    VK_FN(vkGetPhysicalDeviceProperties);
    VK_FN(vkGetPhysicalDeviceQueueFamilyProperties);
    VK_FN(vkGetPhysicalDeviceFeatures2);
    VK_FN(vkEnumerateDeviceExtensionProperties);
    VK_FN(vkCreateDevice);
    VK_FN(vkDestroyDevice);
    VK_FN(vkGetDeviceQueue);
    VK_FN(vkCreateCommandPool);
    VK_FN(vkDestroyCommandPool);
    VK_FN(vkAllocateCommandBuffers);
    VK_FN(vkFreeCommandBuffers);
    VK_FN(vkBeginCommandBuffer);
    VK_FN(vkEndCommandBuffer);
    VK_FN(vkCreateImage);
    VK_FN(vkDestroyImage);
    VK_FN(vkGetImageMemoryRequirements);
    VK_FN(vkGetPhysicalDeviceMemoryProperties);
    VK_FN(vkAllocateMemory);
    VK_FN(vkFreeMemory);
    VK_FN(vkBindImageMemory);
    VK_FN(vkCreateSemaphore);
    VK_FN(vkDestroySemaphore);
    VK_FN(vkQueueSubmit);
    VK_FN(vkQueueWaitIdle);
    VK_FN(vkDeviceWaitIdle);
#undef VK_FN
};

namespace {

#define LOAD_INSTANCE_FN(ctx_, name_)                                          \
    do {                                                                       \
        (ctx_)->name_ = reinterpret_cast<PFN_##name_>(                         \
            (ctx_)->gipa((ctx_)->instance, #name_));                           \
        if (!(ctx_)->name_) {                                                  \
            MK_VK_LOG(@"Failed to load %s", #name_);                           \
            return false;                                                      \
        }                                                                      \
    } while (0)

bool load_global_fns(MKVulkanContext *c) {
    c->vkCreateInstance = reinterpret_cast<PFN_vkCreateInstance>(
        c->gipa(VK_NULL_HANDLE, "vkCreateInstance"));
    return c->vkCreateInstance != nullptr;
}

bool load_instance_fns(MKVulkanContext *c) {
    LOAD_INSTANCE_FN(c, vkDestroyInstance);
    LOAD_INSTANCE_FN(c, vkEnumeratePhysicalDevices);
    LOAD_INSTANCE_FN(c, vkGetPhysicalDeviceProperties);
    LOAD_INSTANCE_FN(c, vkGetPhysicalDeviceQueueFamilyProperties);
    LOAD_INSTANCE_FN(c, vkGetPhysicalDeviceFeatures2);
    LOAD_INSTANCE_FN(c, vkEnumerateDeviceExtensionProperties);
    LOAD_INSTANCE_FN(c, vkGetPhysicalDeviceMemoryProperties);
    LOAD_INSTANCE_FN(c, vkCreateDevice);
    LOAD_INSTANCE_FN(c, vkDestroyDevice);
    LOAD_INSTANCE_FN(c, vkGetDeviceQueue);
    LOAD_INSTANCE_FN(c, vkCreateCommandPool);
    LOAD_INSTANCE_FN(c, vkDestroyCommandPool);
    LOAD_INSTANCE_FN(c, vkAllocateCommandBuffers);
    LOAD_INSTANCE_FN(c, vkFreeCommandBuffers);
    LOAD_INSTANCE_FN(c, vkBeginCommandBuffer);
    LOAD_INSTANCE_FN(c, vkEndCommandBuffer);
    LOAD_INSTANCE_FN(c, vkCreateImage);
    LOAD_INSTANCE_FN(c, vkDestroyImage);
    LOAD_INSTANCE_FN(c, vkGetImageMemoryRequirements);
    LOAD_INSTANCE_FN(c, vkAllocateMemory);
    LOAD_INSTANCE_FN(c, vkFreeMemory);
    LOAD_INSTANCE_FN(c, vkBindImageMemory);
    LOAD_INSTANCE_FN(c, vkCreateSemaphore);
    LOAD_INSTANCE_FN(c, vkDestroySemaphore);
    LOAD_INSTANCE_FN(c, vkQueueSubmit);
    LOAD_INSTANCE_FN(c, vkQueueWaitIdle);
    LOAD_INSTANCE_FN(c, vkDeviceWaitIdle);
    return true;
}

bool create_instance(MKVulkanContext *c) {
    static const char *kInstanceExts[] = {
        VK_KHR_SURFACE_EXTENSION_NAME,
        VK_EXT_METAL_SURFACE_EXTENSION_NAME,
        VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME,
        VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME,
        VK_KHR_EXTERNAL_MEMORY_CAPABILITIES_EXTENSION_NAME,
    };

    VkApplicationInfo app{};
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "media_kit";
    app.apiVersion = VK_API_VERSION_1_2;

    VkInstanceCreateInfo ici{};
    ici.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ici.flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    ici.pApplicationInfo = &app;
    ici.enabledExtensionCount = sizeof(kInstanceExts) / sizeof(kInstanceExts[0]);
    ici.ppEnabledExtensionNames = kInstanceExts;

    VkResult rc = c->vkCreateInstance(&ici, nullptr, &c->instance);
    if (rc != VK_SUCCESS) {
        MK_VK_LOG(@"vkCreateInstance failed: %d", rc);
        return false;
    }
    return true;
}

bool pick_physical_device(MKVulkanContext *c) {
    uint32_t n = 0;
    if (c->vkEnumeratePhysicalDevices(c->instance, &n, nullptr) != VK_SUCCESS || n == 0) {
        MK_VK_LOG(@"No Vulkan physical devices found.");
        return false;
    }
    std::vector<VkPhysicalDevice> devs(n);
    c->vkEnumeratePhysicalDevices(c->instance, &n, devs.data());

    for (auto pd : devs) {
        uint32_t qfn = 0;
        c->vkGetPhysicalDeviceQueueFamilyProperties(pd, &qfn, nullptr);
        std::vector<VkQueueFamilyProperties> qf(qfn);
        c->vkGetPhysicalDeviceQueueFamilyProperties(pd, &qfn, qf.data());
        for (uint32_t i = 0; i < qfn; i++) {
            if ((qf[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) &&
                (qf[i].queueFlags & VK_QUEUE_COMPUTE_BIT))
            {
                c->phys = pd;
                c->qf_index = i;
                c->qf_count = 1;
                return true;
            }
        }
    }
    MK_VK_LOG(@"No physical device with combined graphics+compute queue.");
    return false;
}

bool create_device(MKVulkanContext *c) {
    // Required device extensions for Metal interop + libplacebo happy path.
    // We only request what is also reported as available by the driver.
    uint32_t n = 0;
    c->vkEnumerateDeviceExtensionProperties(c->phys, nullptr, &n, nullptr);
    std::vector<VkExtensionProperties> avail(n);
    c->vkEnumerateDeviceExtensionProperties(c->phys, nullptr, &n, avail.data());

    auto has = [&](const char *want) {
        for (auto &e : avail)
            if (strcmp(e.extensionName, want) == 0)
                return true;
        return false;
    };

    static const char *kWanted[] = {
        VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME,
        VK_KHR_SWAPCHAIN_EXTENSION_NAME,
        "VK_EXT_metal_objects",                  // MTLTexture import
        VK_KHR_EXTERNAL_MEMORY_EXTENSION_NAME,
        VK_KHR_DEDICATED_ALLOCATION_EXTENSION_NAME,
        VK_KHR_GET_MEMORY_REQUIREMENTS_2_EXTENSION_NAME,
        VK_KHR_BIND_MEMORY_2_EXTENSION_NAME,
        VK_KHR_MAINTENANCE1_EXTENSION_NAME,
        VK_KHR_MAINTENANCE2_EXTENSION_NAME,
        VK_KHR_MAINTENANCE3_EXTENSION_NAME,
        VK_KHR_IMAGE_FORMAT_LIST_EXTENSION_NAME,
    };
    for (auto e : kWanted) {
        if (has(e))
            c->dev_exts.push_back(e);
    }

    // Query features once and pass them straight through to libmpv. libplacebo
    // requires features2.
    c->features2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
    c->vkGetPhysicalDeviceFeatures2(c->phys, &c->features2);

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci{};
    qci.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    qci.queueFamilyIndex = c->qf_index;
    qci.queueCount = c->qf_count;
    qci.pQueuePriorities = &prio;

    VkDeviceCreateInfo dci{};
    dci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    dci.pNext = &c->features2;
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qci;
    dci.enabledExtensionCount = (uint32_t)c->dev_exts.size();
    dci.ppEnabledExtensionNames = c->dev_exts.data();

    if (c->vkCreateDevice(c->phys, &dci, nullptr, &c->device) != VK_SUCCESS) {
        MK_VK_LOG(@"vkCreateDevice failed.");
        return false;
    }
    c->vkGetDeviceQueue(c->device, c->qf_index, 0, &c->queue);

    VkCommandPoolCreateInfo cpci{};
    cpci.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    cpci.flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT |
                 VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    cpci.queueFamilyIndex = c->qf_index;
    if (c->vkCreateCommandPool(c->device, &cpci, nullptr, &c->pool) != VK_SUCCESS) {
        MK_VK_LOG(@"vkCreateCommandPool failed.");
        return false;
    }
    return true;
}

} // namespace

// --- C API -------------------------------------------------------------------

struct MKVulkanImage {
    VkImage        image  = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    uint32_t       format = 0;
    uint32_t       usage  = 0;
};

extern "C" {

MKVulkanContext *mk_vk_context_create(void) {
    auto *c = new MKVulkanContext();
    c->gipa = resolve_loader();
    if (!c->gipa) { delete c; return nullptr; }
    if (!load_global_fns(c) || !create_instance(c) || !load_instance_fns(c) ||
        !pick_physical_device(c) || !create_device(c))
    {
        mk_vk_context_destroy(c);
        return nullptr;
    }
    return c;
}

void mk_vk_context_destroy(MKVulkanContext *c) {
    if (!c) return;
    if (c->device) {
        if (c->vkDeviceWaitIdle) c->vkDeviceWaitIdle(c->device);
        if (c->pool && c->vkDestroyCommandPool)
            c->vkDestroyCommandPool(c->device, c->pool, nullptr);
        if (c->vkDestroyDevice) c->vkDestroyDevice(c->device, nullptr);
    }
    if (c->instance && c->vkDestroyInstance)
        c->vkDestroyInstance(c->instance, nullptr);
    delete c;
}

void *mk_vk_context_instance(MKVulkanContext *c)        { return c ? (void*)c->instance : nullptr; }
void *mk_vk_context_phys_device(MKVulkanContext *c)     { return c ? (void*)c->phys : nullptr; }
void *mk_vk_context_device(MKVulkanContext *c)          { return c ? (void*)c->device : nullptr; }
uint32_t mk_vk_context_queue_family_index(MKVulkanContext *c) { return c ? c->qf_index : 0; }
uint32_t mk_vk_context_queue_count(MKVulkanContext *c)  { return c ? c->qf_count : 0; }
void *mk_vk_context_get_proc_addr(MKVulkanContext *c)   { return c ? (void*)c->gipa : nullptr; }
const void *mk_vk_context_features(MKVulkanContext *c)  { return c ? (const void*)&c->features2 : nullptr; }

const char *const *mk_vk_context_device_extensions(MKVulkanContext *c, size_t *out_count) {
    if (!c || !out_count) { if (out_count) *out_count = 0; return nullptr; }
    *out_count = c->dev_exts.size();
    return c->dev_exts.data();
}

void mk_vk_context_lock_queue(void *ctx, uint32_t qf, uint32_t qi) {
    (void)qf; (void)qi;
    auto *c = static_cast<MKVulkanContext *>(ctx);
    if (c) c->queue_mutex.lock();
}
void mk_vk_context_unlock_queue(void *ctx, uint32_t qf, uint32_t qi) {
    (void)qf; (void)qi;
    auto *c = static_cast<MKVulkanContext *>(ctx);
    if (c) c->queue_mutex.unlock();
}

// --- Image import -----------------------------------------------------------

// VK_EXT_metal_objects: VkImportMetalTextureInfoEXT goes in the pNext chain
// of VkImageCreateInfo so that the resulting VkImage is backed by the same
// MTLTexture storage. No separate vkAllocateMemory / vkBindImageMemory is
// required for an imported image -- the spec says the image is fully bound
// at create time.
//
// We keep the struct definition local so we don't depend on a recent
// vulkan_metal.h that may or may not have shipped with the SDK.
typedef enum {
    MK_VK_STRUCTURE_TYPE_IMPORT_METAL_TEXTURE_INFO_EXT = 1000311004,
} MKVkExtMetalObjectsStructType;

typedef struct MKVkImportMetalTextureInfoEXT {
    VkStructureType        sType;
    const void            *pNext;
    VkImageAspectFlagBits  plane;
    void                  *mtlTexture; // id<MTLTexture>
} MKVkImportMetalTextureInfoEXT;

MKVulkanImage *mk_vk_image_import_mtl(MKVulkanContext *c,
                                      void *mtl_texture,
                                      uint32_t width,
                                      uint32_t height,
                                      uint32_t *out_format,
                                      uint32_t *out_usage)
{
    if (!c || !mtl_texture || !out_format || !out_usage) return nullptr;

    id<MTLTexture> mtl = (__bridge id<MTLTexture>)mtl_texture;

    // Pick a VkFormat that mirrors the MTLPixelFormat. media_kit's existing
    // texture uses bgra8Unorm; for HDR users may switch to rgba16Float later.
    VkFormat fmt;
    switch ((NSUInteger)[mtl pixelFormat]) {
        case MTLPixelFormatBGRA8Unorm:       fmt = VK_FORMAT_B8G8R8A8_UNORM;        break;
        case MTLPixelFormatBGRA8Unorm_sRGB:  fmt = VK_FORMAT_B8G8R8A8_SRGB;         break;
        case MTLPixelFormatRGBA8Unorm:       fmt = VK_FORMAT_R8G8B8A8_UNORM;        break;
        case MTLPixelFormatRGBA16Float:      fmt = VK_FORMAT_R16G16B16A16_SFLOAT;   break;
        case MTLPixelFormatBGR10A2Unorm:     fmt = VK_FORMAT_A2R10G10B10_UNORM_PACK32; break;
        default:
            MK_VK_LOG(@"Unsupported MTLPixelFormat for Vulkan import: %lu",
                      (unsigned long)[mtl pixelFormat]);
            return nullptr;
    }

    auto *img = new MKVulkanImage();
    img->format = fmt;
    img->usage  = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                  VK_IMAGE_USAGE_SAMPLED_BIT |
                  VK_IMAGE_USAGE_STORAGE_BIT |
                  VK_IMAGE_USAGE_TRANSFER_DST_BIT;

    MKVkImportMetalTextureInfoEXT mtli{};
    mtli.sType = (VkStructureType)MK_VK_STRUCTURE_TYPE_IMPORT_METAL_TEXTURE_INFO_EXT;
    mtli.plane = VK_IMAGE_ASPECT_COLOR_BIT;
    mtli.mtlTexture = mtl_texture;

    VkImageCreateInfo ici{};
    ici.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    ici.pNext = &mtli;
    ici.imageType = VK_IMAGE_TYPE_2D;
    ici.format = fmt;
    ici.extent = { width, height, 1 };
    ici.mipLevels = 1;
    ici.arrayLayers = 1;
    ici.samples = VK_SAMPLE_COUNT_1_BIT;
    ici.tiling = VK_IMAGE_TILING_OPTIMAL;
    ici.usage = (VkImageUsageFlags)img->usage;
    ici.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    ici.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;

    if (c->vkCreateImage(c->device, &ici, nullptr, &img->image) != VK_SUCCESS) {
        MK_VK_LOG(@"vkCreateImage(metal-import) failed.");
        delete img;
        return nullptr;
    }

    *out_format = (uint32_t)fmt;
    *out_usage  = img->usage;
    return img;
}

void mk_vk_image_destroy(MKVulkanContext *c, MKVulkanImage *img) {
    if (!c || !img) return;
    if (img->image)  c->vkDestroyImage(c->device, img->image, nullptr);
    if (img->memory) c->vkFreeMemory(c->device, img->memory, nullptr);
    delete img;
}

uint64_t mk_vk_image_handle(MKVulkanImage *img) {
    return img ? (uint64_t)(uintptr_t)img->image : 0;
}

// --- Semaphores / sync ------------------------------------------------------

uint64_t mk_vk_semaphore_create(MKVulkanContext *c) {
    if (!c) return 0;
    VkSemaphore sem = VK_NULL_HANDLE;
    VkSemaphoreCreateInfo sci{};
    sci.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    if (c->vkCreateSemaphore(c->device, &sci, nullptr, &sem) != VK_SUCCESS)
        return 0;
    return (uint64_t)(uintptr_t)sem;
}

void mk_vk_semaphore_destroy(MKVulkanContext *c, uint64_t sem) {
    if (!c || !sem) return;
    c->vkDestroySemaphore(c->device, (VkSemaphore)(uintptr_t)sem, nullptr);
}

void mk_vk_wait_semaphore_blocking(MKVulkanContext *c, uint64_t sem) {
    if (!c || !sem) return;
    VkSemaphore vsem = (VkSemaphore)(uintptr_t)sem;

    // Submit an empty queue submission that waits on `sem`. Pair with
    // vkQueueWaitIdle so the host knows the GPU is done. v1 implementation:
    // simple, blocks the worker thread for <= one frame.
    VkPipelineStageFlags stage = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
    VkSubmitInfo si{};
    si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    si.waitSemaphoreCount = 1;
    si.pWaitSemaphores = &vsem;
    si.pWaitDstStageMask = &stage;

    {
        std::lock_guard<std::mutex> lk(c->queue_mutex);
        c->vkQueueSubmit(c->queue, 1, &si, VK_NULL_HANDLE);
        c->vkQueueWaitIdle(c->queue);
    }
}

} // extern "C"
