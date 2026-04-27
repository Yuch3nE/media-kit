// MediaKitVulkanShim.h
//
// Pure-C surface that bridges Swift to a MoltenVK-backed Vulkan device.
//
// This shim's purpose is to host the Vulkan instance/device lifecycle that
// libmpv's Vulkan render backend (MPV_RENDER_API_TYPE_VULKAN, see
// mpv/render_vk.h) requires from its embedder, plus the Metal <-> Vulkan
// interop pieces (importing an MTLTexture as a VkImage, creating a binary
// VkSemaphore for the render-done handoff).
//
// The shim deliberately exposes only opaque pointers / primitive types so
// that it can be consumed straight from Swift via the bridging header.
//
// Failure handling:
//   - All `mk_vk_*_create` functions return NULL on failure and log to
//     stderr / NSLog. The Swift side must treat NULL as a hard failure and
//     fall back to TextureHW (OpenGL) or TextureSW.

#ifndef MEDIAKIT_VULKAN_SHIM_H
#define MEDIAKIT_VULKAN_SHIM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MKVulkanContext MKVulkanContext;
typedef struct MKVulkanImage   MKVulkanImage;

// --- Context lifecycle -------------------------------------------------------

// Create a Vulkan instance + logical device targeting the host MoltenVK ICD.
// Internally selects the first physical device that exposes graphics+compute
// in a single queue family and supports VK_EXT_metal_objects.
MKVulkanContext *mk_vk_context_create(void);
void             mk_vk_context_destroy(MKVulkanContext *ctx);

// Accessors used to populate mpv_vulkan_init_params.
void    *mk_vk_context_instance(MKVulkanContext *ctx);          // VkInstance
void    *mk_vk_context_phys_device(MKVulkanContext *ctx);       // VkPhysicalDevice
void    *mk_vk_context_device(MKVulkanContext *ctx);            // VkDevice
uint32_t mk_vk_context_queue_family_index(MKVulkanContext *ctx);
uint32_t mk_vk_context_queue_count(MKVulkanContext *ctx);
void    *mk_vk_context_get_proc_addr(MKVulkanContext *ctx);     // PFN_vkGetInstanceProcAddr
const void *mk_vk_context_features(MKVulkanContext *ctx);       // VkPhysicalDeviceFeatures2*
const char *const *mk_vk_context_device_extensions(MKVulkanContext *ctx,
                                                   size_t *out_count);

// Queue lock/unlock callbacks. Forwarded straight to libplacebo via libmpv.
void mk_vk_context_lock_queue(void *ctx, uint32_t qf, uint32_t qi);
void mk_vk_context_unlock_queue(void *ctx, uint32_t qf, uint32_t qi);

// --- Per-frame Metal <-> Vulkan plumbing -------------------------------------

// Import an MTLTexture (typed as void* / id<MTLTexture>) as a VkImage usable
// as a render target. width/height must match the MTLTexture extent.
//
// On success, *out_format and *out_usage receive the VkFormat / VkImageUsageFlags
// the resulting VkImage was created with. The caller passes them straight
// through into mpv_vulkan_image.
MKVulkanImage *mk_vk_image_import_mtl(MKVulkanContext *ctx,
                                      void *mtl_texture,
                                      uint32_t width,
                                      uint32_t height,
                                      uint32_t *out_format,
                                      uint32_t *out_usage);
void           mk_vk_image_destroy(MKVulkanContext *ctx, MKVulkanImage *img);
uint64_t       mk_vk_image_handle(MKVulkanImage *img); // VkImage as uint64_t

// Create / destroy a binary VkSemaphore. Lifetime is the host's responsibility.
uint64_t mk_vk_semaphore_create(MKVulkanContext *ctx);
void     mk_vk_semaphore_destroy(MKVulkanContext *ctx, uint64_t semaphore);

// Create a Vulkan timeline semaphore that is backed by an MTLSharedEvent
// (typed as void* / id<MTLSharedEvent>). The same payload value space is
// shared between the Metal and Vulkan sides, enabling lock-free cross-API
// synchronization without vkQueueWaitIdle.
//
// Returns 0 if VK_EXT_metal_objects (or timeline semaphore support) is
// unavailable on the active device. The caller must fall back to
// mk_vk_semaphore_create + mk_vk_wait_semaphore_blocking in that case.
uint64_t mk_vk_semaphore_import_mtl_event(MKVulkanContext *ctx,
                                          void *mtl_shared_event);

// Returns true if the underlying device supports VK_KHR_timeline_semaphore
// AND VK_EXT_metal_objects MTLSharedEvent import. Cached after first probe.
bool mk_vk_supports_metal_event_sync(MKVulkanContext *ctx);

// After mpv has signalled `semaphore` from inside mpv_render_context_render,
// the host must wait on it before letting Metal sample the underlying
// MTLTexture. This call submits an empty queue submission that waits on
// the semaphore and then blocks (vkQueueWaitIdle) until completion.
//
// This is the simple, correct v1 implementation. A future revision can
// replace it with a VK_KHR_external_semaphore_metal export to a
// MTLSharedEvent so Metal can wait async on its own queue.
void mk_vk_wait_semaphore_blocking(MKVulkanContext *ctx, uint64_t semaphore);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // MEDIAKIT_VULKAN_SHIM_H
