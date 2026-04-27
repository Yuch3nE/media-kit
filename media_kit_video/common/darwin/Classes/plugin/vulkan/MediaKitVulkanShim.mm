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

#ifndef VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME
#define VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME "VK_KHR_portability_subset"
#endif

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
    // Search order:
    //   1. App-bundle copies (so the app is self-contained and does not
    //      depend on a system / Homebrew install at runtime).
    //   2. The Vulkan loader framework media_kit_libs_macos_video already
    //      ships in the bundle (still requires an ICD on disk; will fail
    //      with -9 if MoltenVK is not bundled, in which case we keep
    //      walking).
    //   3. Common system / Homebrew install paths as a last-resort fallback
    //      for development setups.
    static const char *candidates[] = {
        // 1. Bundled MoltenVK (preferred)
        "@executable_path/../Frameworks/libMoltenVK.dylib",
        "@loader_path/../Frameworks/libMoltenVK.dylib",
        "@executable_path/../Frameworks/libvulkan.dylib",
        "@executable_path/../Frameworks/libvulkan.1.dylib",
        // 2. Bundled Vulkan loader framework
        "@executable_path/../Frameworks/Vulkan.framework/Vulkan",
        "@loader_path/../Frameworks/Vulkan.framework/Vulkan",
        // 3. System / Homebrew (development fallback only)
        "libMoltenVK.dylib",
        "libvulkan.dylib",
        "libvulkan.1.dylib",
        "/opt/homebrew/opt/molten-vk/lib/libMoltenVK.dylib",
        "/opt/homebrew/lib/libMoltenVK.dylib",
        "/usr/local/opt/molten-vk/lib/libMoltenVK.dylib",
        "/usr/local/lib/libMoltenVK.dylib",
        "/opt/homebrew/lib/libvulkan.dylib",
        "/opt/homebrew/lib/libvulkan.1.dylib",
        "/opt/homebrew/opt/vulkan-loader/lib/libvulkan.dylib",
        "/usr/local/lib/libvulkan.dylib",
        "/usr/local/lib/libvulkan.1.dylib",
        "/usr/local/opt/vulkan-loader/lib/libvulkan.dylib",
        nullptr,
    };
    for (int i = 0; candidates[i]; i++) {
        void *handle = dlopen(candidates[i], RTLD_LAZY | RTLD_LOCAL);
        if (!handle) {
            const char *err = dlerror();
            if (err && strstr(candidates[i], "@") == nullptr &&
                strstr(candidates[i], "/") != nullptr) {
                // Only log absolute / explicit paths so the noisy bundle
                // probes do not spam.
                MK_VK_LOG(@"dlopen(%s) failed: %s", candidates[i], err);
            }
            continue;
        }
        auto fn = reinterpret_cast<PFN_vkGetInstanceProcAddr>(
            dlsym(handle, "vkGetInstanceProcAddr"));
        if (fn) {
            return fn;
        }
        dlclose(handle);
    }
    MK_VK_LOG(@"No Vulkan loader found (tried bundle, libvulkan, libMoltenVK).");
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
    VkPhysicalDeviceVulkan12Features vulkan12{};

    bool has_timeline_semaphore = false;
    bool has_metal_objects = false;

    std::vector<const char *> dev_exts;
    std::mutex                queue_mutex;

#define VK_FN(name) PFN_##name name = nullptr
    VK_FN(vkCreateInstance);
    VK_FN(vkEnumerateInstanceExtensionProperties);
    VK_FN(vkDestroyInstance);
    VK_FN(vkEnumeratePhysicalDevices);
    VK_FN(vkGetPhysicalDeviceProperties);
    VK_FN(vkGetPhysicalDeviceQueueFamilyProperties);
    VK_FN(vkGetPhysicalDeviceFeatures2);
    VK_FN(vkEnumerateDeviceExtensionProperties);
    VK_FN(vkCreateDevice);
    VK_FN(vkDestroyDevice);
    VK_FN(vkGetDeviceProcAddr);
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
    c->vkEnumerateInstanceExtensionProperties =
        reinterpret_cast<PFN_vkEnumerateInstanceExtensionProperties>(
            c->gipa(VK_NULL_HANDLE, "vkEnumerateInstanceExtensionProperties"));
    return c->vkCreateInstance != nullptr &&
           c->vkEnumerateInstanceExtensionProperties != nullptr;
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
    LOAD_INSTANCE_FN(c, vkGetDeviceProcAddr);
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
    uint32_t ext_count = 0;
    c->vkEnumerateInstanceExtensionProperties(nullptr, &ext_count, nullptr);
    std::vector<VkExtensionProperties> ext_props(ext_count);
    if (ext_count > 0) {
        c->vkEnumerateInstanceExtensionProperties(
            nullptr,
            &ext_count,
            ext_props.data());
    }

    auto has_instance_ext = [&](const char *want) {
        for (const auto &ext : ext_props) {
            if (strcmp(ext.extensionName, want) == 0) {
                return true;
            }
        }
        return false;
    };

    std::vector<const char *> instance_exts;
    if (has_instance_ext(VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME)) {
        instance_exts.push_back(
            VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME);
    }
    if (has_instance_ext(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)) {
        instance_exts.push_back(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);
    }

    VkApplicationInfo app{};
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "media_kit";
    app.apiVersion = VK_API_VERSION_1_2;

    VkInstanceCreateInfo ici{};
    ici.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    if (has_instance_ext(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)) {
        ici.flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    }
    ici.pApplicationInfo = &app;
    ici.enabledExtensionCount = static_cast<uint32_t>(instance_exts.size());
    ici.ppEnabledExtensionNames = instance_exts.data();

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
        "VK_EXT_metal_objects",                  // MTLTexture/MTLSharedEvent import
        "VK_EXT_external_memory_metal",          // METAL_TEXTURE_BIT_EXT handle type
        VK_KHR_EXTERNAL_MEMORY_EXTENSION_NAME,
        VK_KHR_EXTERNAL_SEMAPHORE_EXTENSION_NAME,
        VK_KHR_TIMELINE_SEMAPHORE_EXTENSION_NAME,
        VK_KHR_DEDICATED_ALLOCATION_EXTENSION_NAME,
        VK_KHR_GET_MEMORY_REQUIREMENTS_2_EXTENSION_NAME,
        VK_KHR_BIND_MEMORY_2_EXTENSION_NAME,
        VK_KHR_MAINTENANCE1_EXTENSION_NAME,
        VK_KHR_MAINTENANCE2_EXTENSION_NAME,
        VK_KHR_MAINTENANCE3_EXTENSION_NAME,
        VK_KHR_IMAGE_FORMAT_LIST_EXTENSION_NAME,
    };
    for (const char *e : kWanted) {
        if (has(e)) {
            c->dev_exts.push_back(e);
            if (strcmp(e, VK_KHR_TIMELINE_SEMAPHORE_EXTENSION_NAME) == 0)
                c->has_timeline_semaphore = true;
            if (strcmp(e, "VK_EXT_metal_objects") == 0)
                c->has_metal_objects = true;
        }
    }

    // Query features once and pass them straight through to libmpv. libplacebo
    // requires the exact enabled feature chain. In practice on MoltenVK this
    // needs Vulkan 1.2 features so hostQueryReset is visible and enabled.
    c->features2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
    c->vulkan12.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES;
    c->features2.pNext = &c->vulkan12;
    c->vkGetPhysicalDeviceFeatures2(c->phys, &c->features2);

    if (!c->vulkan12.hostQueryReset) {
        MK_VK_LOG(@"Device missing required Vulkan feature: hostQueryReset");
        return false;
    }

    if (c->has_timeline_semaphore && !c->vulkan12.timelineSemaphore) {
        // Driver does not actually support timelines despite the extension
        // being listed. Drop our claim so device creation does not assert.
        c->has_timeline_semaphore = false;
        c->vulkan12.timelineSemaphore = VK_FALSE;
    }

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

    // Per Vulkan spec, device-level entry points should be resolved via
    // vkGetDeviceProcAddr to bypass loader trampolines. Required for
    // correctness when running through MoltenVK and gives a small dispatch
    // win on multi-device hosts.
#define LOAD_DEVICE_FN(name_)                                                  \
    do {                                                                       \
        auto fn = reinterpret_cast<PFN_##name_>(                               \
            c->vkGetDeviceProcAddr(c->device, #name_));                        \
        if (fn) c->name_ = fn;                                                 \
    } while (0)
    LOAD_DEVICE_FN(vkDestroyDevice);
    LOAD_DEVICE_FN(vkGetDeviceQueue);
    LOAD_DEVICE_FN(vkCreateCommandPool);
    LOAD_DEVICE_FN(vkDestroyCommandPool);
    LOAD_DEVICE_FN(vkAllocateCommandBuffers);
    LOAD_DEVICE_FN(vkFreeCommandBuffers);
    LOAD_DEVICE_FN(vkBeginCommandBuffer);
    LOAD_DEVICE_FN(vkEndCommandBuffer);
    LOAD_DEVICE_FN(vkCreateImage);
    LOAD_DEVICE_FN(vkDestroyImage);
    LOAD_DEVICE_FN(vkGetImageMemoryRequirements);
    LOAD_DEVICE_FN(vkAllocateMemory);
    LOAD_DEVICE_FN(vkFreeMemory);
    LOAD_DEVICE_FN(vkBindImageMemory);
    LOAD_DEVICE_FN(vkCreateSemaphore);
    LOAD_DEVICE_FN(vkDestroySemaphore);
    LOAD_DEVICE_FN(vkQueueSubmit);
    LOAD_DEVICE_FN(vkQueueWaitIdle);
    LOAD_DEVICE_FN(vkDeviceWaitIdle);
#undef LOAD_DEVICE_FN

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
    // Per VK_EXT_metal_objects spec:
    //   1000311004 EXPORT_METAL_BUFFER_INFO_EXT
    //   1000311005 IMPORT_METAL_BUFFER_INFO_EXT
    //   1000311006 EXPORT_METAL_TEXTURE_INFO_EXT
    //   1000311007 IMPORT_METAL_TEXTURE_INFO_EXT  <-- correct value
    // Using the wrong sType makes MoltenVK silently ignore the pNext entry
    // and allocate its own backing MTLTexture instead of importing ours,
    // causing the IOSurface to stay all zeros even though every Vulkan
    // call returns success.
    MK_VK_STRUCTURE_TYPE_IMPORT_METAL_TEXTURE_INFO_EXT = 1000311007,
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
    // Intentionally exclude VK_IMAGE_USAGE_STORAGE_BIT: on MoltenVK / Metal,
    // MTLPixelFormatBGRA8Unorm does not support shader read+write storage.
    // Mixing STORAGE into the import usage causes vkCreateImage(metal-import)
    // to fail for any non-trivial size (e.g. 3840x2160). gpu-next/libplacebo
    // only needs the target as a color attachment + sampled source + blit
    // destination, none of which require STORAGE.
    img->usage  = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                  VK_IMAGE_USAGE_SAMPLED_BIT |
                  VK_IMAGE_USAGE_TRANSFER_DST_BIT;

    MKVkImportMetalTextureInfoEXT mtli{};
    mtli.sType = (VkStructureType)MK_VK_STRUCTURE_TYPE_IMPORT_METAL_TEXTURE_INFO_EXT;
    mtli.plane = VK_IMAGE_ASPECT_COLOR_BIT;
    mtli.mtlTexture = mtl_texture;

    // IMPORTANT: do NOT also chain VkExternalMemoryImageCreateInfo here.
    // VkImportMetalTextureInfoEXT is MoltenVK's native metal-import path:
    // when present, MoltenVK marks the VkImage as 'externally owned' and
    // uses the supplied MTLTexture as its backing storage directly. We do
    // not call vkAllocateMemory / vkBindImageMemory in that case.
    //
    // Mixing in VkExternalMemoryImageCreateInfo would tell MoltenVK to
    // expect a separately-imported VkDeviceMemory (via
    // VkImportMemoryMetalHandleInfoEXT) and made it allocate its own
    // internal Metal texture instead, so renders never landed in our
    // IOSurface and Flutter saw a fully black frame even though every
    // Vulkan call returned VK_SUCCESS.
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

    if (VkResult vr = c->vkCreateImage(c->device, &ici, nullptr, &img->image); vr != VK_SUCCESS) {
        MK_VK_LOG(@"vkCreateImage(metal-import) failed (VkResult=%d, ext=%ux%u, fmt=%d, usage=0x%x).",
                  (int)vr, width, height, (int)fmt, (unsigned)img->usage);
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

    // The imported device currently exposes exactly one queue in the family
    // handed to mpv. Waiting that queue idle is sufficient to know mpv's
    // earlier rendering work has completed and avoids an extra wait-only
    // submission, which can stall indefinitely on MoltenVK.
    std::lock_guard<std::mutex> lk(c->queue_mutex);
    c->vkQueueWaitIdle(c->queue);
}

void mk_vk_wait_device_idle(MKVulkanContext *c) {
    if (!c || !c->device || !c->vkDeviceWaitIdle) return;
    std::lock_guard<std::mutex> lk(c->queue_mutex);
    c->vkDeviceWaitIdle(c->device);
}

bool mk_vk_supports_metal_event_sync(MKVulkanContext *c) {
    return c && c->has_timeline_semaphore && c->has_metal_objects;
}

// VK_EXT_metal_objects: VkImportMetalSharedEventInfoEXT goes in the pNext
// chain of VkSemaphoreCreateInfo (combined with a timeline-semaphore type)
// to produce a VkSemaphore whose payload is the same MTLSharedEvent value
// the host can observe / signal from Metal command buffers.
typedef struct MKVkImportMetalSharedEventInfoEXT {
    VkStructureType  sType;
    const void      *pNext;
    void            *mtlSharedEvent; // id<MTLSharedEvent>
} MKVkImportMetalSharedEventInfoEXT;
enum { MK_VK_STRUCTURE_TYPE_IMPORT_METAL_SHARED_EVENT_INFO_EXT = 1000311006 };

uint64_t mk_vk_semaphore_import_mtl_event(MKVulkanContext *c, void *mtl_event) {
    if (!mk_vk_supports_metal_event_sync(c) || !mtl_event) return 0;

    MKVkImportMetalSharedEventInfoEXT mei{};
    mei.sType = (VkStructureType)MK_VK_STRUCTURE_TYPE_IMPORT_METAL_SHARED_EVENT_INFO_EXT;
    mei.mtlSharedEvent = mtl_event;

    VkSemaphoreTypeCreateInfo stype{};
    stype.sType = VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO;
    stype.pNext = &mei;
    stype.semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE;
    stype.initialValue = 0;

    VkSemaphoreCreateInfo sci{};
    sci.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    sci.pNext = &stype;

    VkSemaphore sem = VK_NULL_HANDLE;
    VkResult rc = c->vkCreateSemaphore(c->device, &sci, nullptr, &sem);
    if (rc != VK_SUCCESS) {
        MK_VK_LOG(@"vkCreateSemaphore(MTLSharedEvent import) failed: %d", rc);
        return 0;
    }
    return (uint64_t)(uintptr_t)sem;
}

} // extern "C"
