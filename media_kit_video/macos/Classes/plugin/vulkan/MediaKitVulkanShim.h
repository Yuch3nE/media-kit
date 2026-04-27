// MediaKitVulkanShim.h
//
// Public wrapper header exposed from the macOS pod source root so CocoaPods
// can add it to the generated umbrella header. Keep declarations in sync with
// the shared implementation under common/darwin/Classes/plugin/vulkan.

#ifndef MEDIAKIT_VULKAN_SHIM_H
#define MEDIAKIT_VULKAN_SHIM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MKVulkanContext MKVulkanContext;
typedef struct MKVulkanImage MKVulkanImage;

MKVulkanContext *mk_vk_context_create(void);
void mk_vk_context_destroy(MKVulkanContext *ctx);

void *mk_vk_context_instance(MKVulkanContext *ctx);
void *mk_vk_context_phys_device(MKVulkanContext *ctx);
void *mk_vk_context_device(MKVulkanContext *ctx);
uint32_t mk_vk_context_queue_family_index(MKVulkanContext *ctx);
uint32_t mk_vk_context_queue_count(MKVulkanContext *ctx);
void *mk_vk_context_get_proc_addr(MKVulkanContext *ctx);
const void *mk_vk_context_features(MKVulkanContext *ctx);
const char *const *mk_vk_context_device_extensions(
	MKVulkanContext *ctx,
	size_t *out_count);

void mk_vk_context_lock_queue(void *ctx, uint32_t qf, uint32_t qi);
void mk_vk_context_unlock_queue(void *ctx, uint32_t qf, uint32_t qi);

MKVulkanImage *mk_vk_image_import_mtl(MKVulkanContext *ctx,
									  void *mtl_texture,
									  uint32_t width,
									  uint32_t height,
									  uint32_t *out_format,
									  uint32_t *out_usage);
void mk_vk_image_destroy(MKVulkanContext *ctx, MKVulkanImage *img);
uint64_t mk_vk_image_handle(MKVulkanImage *img);

uint64_t mk_vk_semaphore_create(MKVulkanContext *ctx);
void mk_vk_semaphore_destroy(MKVulkanContext *ctx, uint64_t semaphore);
uint64_t mk_vk_semaphore_import_mtl_event(MKVulkanContext *ctx,
										  void *mtl_shared_event);
bool mk_vk_supports_metal_event_sync(MKVulkanContext *ctx);
void mk_vk_wait_semaphore_blocking(MKVulkanContext *ctx, uint64_t semaphore);
void mk_vk_wait_device_idle(MKVulkanContext *ctx);

#ifdef __cplusplus
}
#endif

#endif