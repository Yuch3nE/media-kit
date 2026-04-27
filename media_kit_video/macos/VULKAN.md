# macOS Vulkan / MoltenVK 渲染路径

`media_kit_video` 在 macOS 上提供两条 GPU 路径：

| 路径 | 后端 | 适用场景 |
|---|---|---|
| `TextureHW` | OpenGL (CGL) → IOSurface → MTLTexture | 默认；兼容性最好 |
| **`TextureVK`** | **Vulkan / MoltenVK → IOSurface → MTLTexture** | HDR / 宽色域 / 与 mpv `gpu-next` libplacebo 管线对齐 |

本文档记录如何启用 `TextureVK`、运行时自检路径，以及典型故障排查。

---

## 1. 前置依赖

`TextureVK` 依赖一份带 Vulkan 后端的 libmpv，构建阶段必须满足：

- `meson configure -Dvulkan=enabled`（或 mpv-iina-avs 构建脚本自动探测）
- 链接时可解析 `libplacebo` 的 `pl_vulkan_*` 系列符号
- 运行时能加载下列动态库之一（按顺序）：
  - `libvulkan.dylib`
  - `libvulkan.1.dylib`
  - `libMoltenVK.dylib`

只要 mpv 自带 vulkan 编译产物 + 系统装了 MoltenVK（Vulkan SDK / Homebrew `molten-vk` / 应用 bundle 内置），运行时即可拉起。

---

## 2. 启用方式

Dart 端：

```dart
final controller = VideoController(
  player,
  configuration: const VideoControllerConfiguration(
    enableHardwareAcceleration: true,   // 必须 true
    enableVulkanRendering: true,        // 新增字段，默认 false
  ),
);
```

字段沿
`VideoControllerConfiguration` → method channel `VideoOutputManager.Create`
→ Swift `VideoOutputConfiguration.enableVulkanRendering`
→ `VideoOutput._init` → `TextureVK(handle:updateCallback:)` 走完整链路。

`TextureVK` 初始化失败时（缺 MoltenVK / 缺扩展 / `mpv_render_context_create` 报错等）**会自动 fallback 到 `TextureHW`**，对调用方无感。

---

## 3. 运行时验证

控制台关键日志（`NSLog` 经由 Xcode / Console.app 可见）：

| 日志 | 含义 |
|---|---|
| `TextureVK: async sync via MTLSharedEvent + Vk timeline enabled.` | 设备同时支持 `VK_KHR_timeline_semaphore` + `VK_EXT_metal_objects`，跨 API 同步走异步路径 |
| `TextureVK: falling back to vkQueueWaitIdle blocking sync.` | 上述任意扩展缺失，回到 v1 阻塞同步（功能正确，CPU 占用稍高） |
| `TextureVK: failed to create Vulkan context (MoltenVK missing?)` | 无法 dlopen Vulkan loader 或 instance 创建失败；通常是 MoltenVK 缺失或 ICD JSON 没装 |
| `TextureVK: mpv_render_context_create failed: …` | libmpv 报错；查 mpv 日志 `--msg-level=vo=v` |
| `TextureVK: mk_vk_image_import_mtl failed.` | `VK_EXT_metal_objects` 缺失或 `VkImportMetalTextureInfoEXT` 类型不被 MoltenVK 接受 |

校验帧确实走 Vulkan：

```bash
# 设置 mpv 详细日志
export MPV_VERBOSE=1
# 期望看到 vo=libmpv + 'vk' backend 行
```

---

## 4. HDR / 宽色域元数据透传

`TextureVK` 在 macOS 端实现了双向透传：

**宿主 → mpv**

- `NSScreen.didChangeScreenParametersNotification` 触发重探测
- 按 `screen.colorSpace.localizedName` 匹配 `display-p3` / `bt.2020` / `bt.709`
- `screen.maximumExtendedDynamicRangeColorComponentValue > 1.0` 视为 HDR：transfer 切换为 `pq`，max_luma 设为 `maxEDR * 100` cd/m²
- 通过 `MPV_RENDER_PARAM_VK_TARGET_STATE` 主动 push 给 mpv，让 libplacebo 输出符合显示器能力的色彩空间

**mpv → CVPixelBuffer**

每帧渲染完后，`mpv_render_context_get_info(MPV_RENDER_PARAM_VK_COLORSPACE_HINT)` 拿到 `mpv_vulkan_colorspace_hint`，按下表附加到 `CVPixelBuffer`：

| Key | 来源 |
|---|---|
| `kCVImageBufferColorPrimariesKey` | `hint.primaries` 字符串映射 |
| `kCVImageBufferTransferFunctionKey` | `hint.transfer` 字符串映射 |
| `kCVImageBufferYCbCrMatrixKey` | 固定 `_ITU_R_709_2`（RGB pb，仅占位） |
| `kCVImageBufferMasteringDisplayColorVolumeKey` *(仅 HDR)* | 24 字节 H.265 SEI 大端 blob：GBR primaries + white point + max/min display luminance |
| `kCVImageBufferContentLightLevelInfoKey` *(仅 HDR)* | 4 字节 H.265 SEI：max CLL + max FALL |

HDR blob 仅在 `transfer ∈ {pq, hlg}` 且 `max_luma > 0` 时附加，避免 SDR 帧带 stale 元数据。

**手动验证**

```swift
if let pb = textureVK.copyPixelBuffer()?.takeRetainedValue() {
    let attachments = CVBufferGetAttachments(pb, .shouldPropagate) as? [CFString: Any]
    print(attachments?[kCVImageBufferColorPrimariesKey] ?? "nil")
    print(attachments?[kCVImageBufferTransferFunctionKey] ?? "nil")
    print(attachments?[kCVImageBufferMasteringDisplayColorVolumeKey] ?? "nil")
}
```

---

## 5. 跨 API 同步模型

### v2（默认，能力可用时）

- 每个 slot 持有一个 `MTLSharedEvent`
- 通过 `VkImportMetalSharedEventInfoEXT` 把它导入为 timeline `VkSemaphore`
- 每帧 `signal_value` 单调 +1
- mpv 在 Vk 端 signal → Metal 端 `MTLSharedEvent.notify(_:atValue:)` 异步回调
- worker 线程 **不阻塞**，三缓冲流水线可并行推进

### v1 fallback

- 每个 slot 是普通二进制 `VkSemaphore`
- `mk_vk_wait_semaphore_blocking` 提交空 submission 等 sem，`vkQueueWaitIdle` 阻塞 worker 线程一帧
- 行为正确但损失部分吞吐

---

## 6. 故障排查清单

| 症状 | 可能原因 | 排查 |
|---|---|---|
| 启用后日志里仍是 OpenGL | `enableHardwareAcceleration` 没设 true / 字段没透传 | 检查 method channel 上行 payload |
| `TextureVK` 创建立即失败 | MoltenVK 不存在或路径不对 | `otool -L` 看 libmpv 是否能找到 vulkan loader；`open -a Console.app` 搜 `MoltenVK` |
| 帧显示偏色 / 过亮过暗 | colorspace 元数据没正确附加 | 用第 4 节手动 dump 验证 `kCVImageBuffer*` attachments |
| HDR 视频显示成 SDR | `NSScreen.maximumExtendedDynamicRangeColorComponentValue` ≤ 1.0；显示器或 OS EDR 未启用 | 系统设置 → 显示器，确认 HDR 开关；外接 HDR 显示器需要 macOS ≥ 11 |
| 渲染卡顿 / 帧率波动 | v2 异步同步未启用，走的是 vkQueueWaitIdle | 看 `TextureVK: ... blocking sync.` 日志；升级 MoltenVK 至支持 `VK_EXT_metal_objects` 的版本 |
| `vkCreateDevice failed` | `VK_KHR_PORTABILITY_SUBSET` / 必要扩展未在 MoltenVK 中暴露 | 升级 MoltenVK；用 `vulkaninfo` 检查 |

---

## 7. 已知限制（v1 → v2 演进未完成项）

- iOS：尚未实现，`TextureVK.swift` 仅 macOS 编译
- 单 queue family 假设：`pl_vulkan_import` 三个 queue family 字段都填同一个，足够 MoltenVK 但不通用
- `surface_max_cll` / `surface_max_fall`（host → mpv 方向）当前固定 0，未从屏幕能力推导
- HDR blob 中 white point 仅覆盖 D65 / DCI；非常规 white point 需扩展 `chromaticities` 表

## 8. 已应用的内部优化

- `MTLSharedEventListener` 改为类静态单例，避免每个 `TextureVK` 实例额外占用一个系统派发队列
- 屏幕色域识别从 `NSColorSpace.localizedName` 字符串模糊匹配改为 `CGColorSpace.name` 与 `CGColorSpace.displayP3 / itur_2020 / sRGB / itur_709 / dcip3 / *_PQ / *_HLG` 等系统常量精确比对，避开 locale / OS 版本敏感性
