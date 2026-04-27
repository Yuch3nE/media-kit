# macOS Metal 渲染迁移设计

## 现状判断

media_kit_video macOS HW 路径（[TextureHW.swift](../macos/Classes/plugin/TextureHW.swift)）当前依赖 CGL + `CVOpenGLTextureCache`。OpenGL 在 macOS 10.14 起 deprecated，Apple Silicon 上走 GL 兼容层。希望迁到 Metal，但**今天不可行**，根因不在 media_kit，而在上游：

- mpv libmpv render API 只支持 `MPV_RENDER_API_TYPE_OPENGL` / `_SW` / `_DXGI`，没有 `_METAL` 或 `_VULKAN`。
- libplacebo 没有 Metal backend，只有 OpenGL / Vulkan / D3D11。
- Apple 平台上"libplacebo→Metal"的现成路径是 **Vulkan + MoltenVK**（本仓库 macOS bundle 已带 MoltenVK）。

因此可行的"Metal 化"实际有两条路线，都需要上游 mpv 先动。

## 路线 A：Vulkan on MoltenVK（推荐）

复用现有 libplacebo Vulkan backend，无需 libplacebo 新写 Metal 后端。

### 上游 mpv 工作

1. `include/mpv/render.h`：新增 `#define MPV_RENDER_API_TYPE_VULKAN "vulkan"`。
2. 新增 `include/mpv/render_vk.h`：声明 `MPV_RENDER_PARAM_VULKAN_INIT_PARAMS`，包含 `VkInstance` / `VkPhysicalDevice` / `VkDevice` / `queue family index` / `get_proc_addr` 等字段，由调用方提供（mpv 复用而不新建 device，否则 IOSurface 共享会失败）。
3. 新增 `include/mpv/render_vk_target.h`（或扩展 render.h）：定义 `MPV_RENDER_PARAM_VK_IMAGE`（含 `VkImage` / `VkImageLayout` / `width` / `height` / `format` / `signal/wait semaphores`），用于 `mpv_render_context_render`。
4. 新增 `video/out/gpu_next/libmpv_gpu_next_vk.c`：实现 `libmpv_gpu_next_context_fns` 的 vulkan 变体——init 用 `pl_vulkan_create_external` 包外部 device，wrap_fbo 改为 wrap 外部 `VkImage`，done_frame 处理 semaphore signal。
5. `meson.build`：在 `HAVE_VULKAN && PL_HAVE_VULKAN` 下加入新文件。

### media_kit_video macOS 工作

1. 新 `TextureMTL.swift`，结构对齐 `TextureHW`：
   - `MTLDevice`、`MTLCommandQueue` 持有
   - `CVMetalTextureCache` 取代 `CVOpenGLTextureCache`
   - `CVPixelBuffer` 仍用 IOSurface backed，pixel format 可选 BGRA8 / `kCVPixelFormatType_64RGBAHalf` 用于 HDR
   - `CVMetalTextureCacheCreateTextureFromImage` 拿到 `MTLTexture`
2. 引入 MoltenVK + libplacebo Vulkan：
   - 用 `vkCreateInstance` + MoltenVK `MVKConfiguration` 启动一个 Vulkan instance
   - 通过 `VK_EXT_metal_objects`（MoltenVK 已支持）把 `MTLTexture` import 成 `VkImage`，IOSurface 路径不复制
3. 把 `VkInstance/Device` 通过 `MPV_RENDER_PARAM_VULKAN_INIT_PARAMS` 传给 mpv；render 时把 import 出来的 `VkImage` 通过 `MPV_RENDER_PARAM_VK_IMAGE` 传过去
4. 同步：用 `VkSemaphore` ↔ `MTLSharedEvent` 桥接。Flutter 合成器自然在 Metal 队列上读 IOSurface，靠 `MTLSharedEvent.signaledValue` 等待

### 优点 / 缺点

- 优点：libplacebo Vulkan 路径成熟，所有滤镜 / shader / HDR / hwdec 已经可用；不需要造 libplacebo Metal 后端
- 缺点：上层多一层 MoltenVK；要保证 MoltenVK 与系统 / Flutter Metal device 共存；二进制体量增大

## 路线 B：原生 Metal

需要先给 libplacebo 写 Metal backend（pl_metal_create / pl_metal_wrap / pl_metal_swapchain），mpv 再加 `MPV_RENDER_API_TYPE_METAL` 与 `libmpv_gpu_next_metal.c`。工作量是路线 A 的数倍，且 libplacebo 上游目前没有这个计划。短期不考虑。

## 路线 C：保留 OpenGL，仅做 IOSurface ↔ Metal 共享优化

不真正"换 API"，仅承认现状：mpv 用 GL 渲染，Flutter 用 Metal 合成。两边都对 IOSurface 操作。需要补的是跨 API 同步——`MTLSharedEvent` 与 GL 的 `glFlush` + `glFenceSync` 之间没有官方桥接，Apple 公开机制是 `IOSurfaceLock` 或自己用 `MTLSharedEvent` + `glFinish` 强同步。当前我们刚做完的 GL fence 就是这条路上的最大单点改进。

如果不打算近期推动上游，路线 C 是性价比最高的"维护态"。

## 与本仓库的依赖关系

- 路线 A 需要 [mpv-iina-avs/tools/build_ffmpeg_prefix_macos.sh](../../../../mpv-iina-avs/tools/build_ffmpeg_prefix_macos.sh) 已在拉的 MoltenVK + Vulkan loader 真正暴露给 mpv。当前 mpv 默认在 macOS 不开 Vulkan VO，需要打开 `-Dvulkan=enabled`。
- 路线 A 必然要给 mpv 打补丁，归到 [mpv-iina-avs/tools/patches/mpv/](../../../../mpv-iina-avs/tools/patches/mpv/) 下。
- libplacebo 当前以静态库随 ffmpeg 链接，要保证 build 启用 `-Dvulkan=enabled`。

## 建议落地顺序

1. 先在 mpv 上开 Vulkan VO（`vo=gpu-next` + `--gpu-api=vulkan`）跑通，验证 MoltenVK 路径稳定。
2. 写 `MPV_RENDER_API_TYPE_VULKAN` 上游补丁（API 设计 + libmpv_gpu_next_vk.c），先在 mpv-iina-avs patch 队列里迭代。
3. media_kit_video macOS 加 `TextureMTL`，并行保留 `TextureHW` 作为 fallback / 对照。
4. 真机/多设备验证后再决定是否把 OpenGL 路径下线。

## 不做的事

- **不**给 libplacebo 写 Metal backend（路线 B）。
- **不**在 media_kit 一侧用 OpenGL 渲染再"伪装"成 Metal——IOSurface 已经是共享桥梁，不需要也无法从 media_kit 端单独"换 API"。
- **不**在没有上游 mpv API 的前提下硬启 Metal 流程（这会要求绕过 mpv 重新实现整套渲染，等于另写一套媒体播放器）。
