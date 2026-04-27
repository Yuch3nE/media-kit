# macOS 渲染路径笔记

针对 `media_kit_video/macos` 下硬件加速路径（`TextureHW` + `gpu-next` libmpv 后端）记录现状、近期改动与遗留项。SW 路径（`TextureSW`）不在此范围。

## 数据流

1. `OpenGLHelpers.createPixelBuffer()` 通过 `kCVPixelBufferMetalCompatibilityKey` 分配 `CVPixelBuffer`，隐式带 IOSurface。
2. `OpenGLHelpers.createTexture()` 经 `CVOpenGLTextureCache` 把同一 IOSurface 包装为 `CVOpenGLTexture`（GL 端句柄）。
3. `TextureHW.render()` 把该纹理挂到 FBO，调用 `mpv_render_context_render` 让 gpu-next 直接渲染到 IOSurface。
4. `copyPixelBuffer()` 把同一 `CVPixelBuffer` 移交 Flutter 合成器；后者直接消费 IOSurface。

整条路径无 CPU 读回；triple buffer 由 `SwappableObjectManager<TextureGLContext>` 管理。

## 近期改动

### 1. 移除冗余 depth/stencil RenderBuffer

mpv 渲染只写颜色，原先每个 FBO 都附带一份 `GL_DEPTH24_STENCIL8`，按分辨率 ×3（triple buffer）浪费显存。`OpenGLHelpers.createRenderBuffer/deleteRenderBuffer` 与 `TextureGLContext.renderBuffer` 一并删除。

### 2. 修复 IOSurface 缓存运行期泄漏

`glDeleteTextures` 不会让 `CVOpenGLTextureCache` 释放其内部对 IOSurface 的引用；resize 时旧 IOSurface 持续累积，直到整个 cache 在 `deinit` 时被销毁。`disposePixelBuffer()` 增加 `CVOpenGLTextureCacheFlush(textureCache, 0)`。

### 3. 三缓冲 GL fence 同步

原本 `render()` 仅 `glFlush()` 后立即 `pushAsReady`，`glFlush` 只把命令交给驱动，不保证 GPU 完成。Flutter 合成可能撕裂或读到上一帧。

新方案：在 `TextureGLContext` 上挂一个 `GLsync`：

- `render()` 拿到 slot 后先 `waitAndClearFence()`，等其上一次写完。
- `glFlush()` 后 `insertFence()` 标记新一次完成点。

triple buffer 仍可流水化（fence 落在不同 slot 上，互不阻塞），但保证 Flutter 永远拿到完整帧。

### 4. 不再注入 NSScreen ICC profile

`media_kit_video` 的 macOS OpenGL 路径通过 IOSurface 把渲染结果交给 Flutter / CoreAnimation 合成。这里如果把 `NSScreen` 的 ICC profile 主动注入给 gpu-next，mpv 会先把输出变换到屏幕色域，而系统合成阶段又会把这块未显式标记色域的 BGRA IOSurface 当作 sRGB 再转换一次，形成双重色彩管理。

直接表现就是中间调和半透明元素被冲淡，字幕的描边、抗锯齿边缘和阴影最容易看出发灰、发淡。

因此当前实现不再调用 `MPV_RENDER_PARAM_ICC_PROFILE`，也不在该路径上启用 `icc-profile-auto`。如果后续要恢复精确的宽色域输出，前提是先让宿主纹理携带正确的 colorspace 元数据，或改成能显式表达目标色域的渲染链路。

另外，OpenGL 路径现在会在每个输出 `CVPixelBuffer` 上显式附加 sRGB / BT.709 的 CoreVideo 色彩元数据，避免未标记的 BGRA `IOSurface` 被 CoreAnimation 按不一致的默认色域解释，导致 SDR 内容尤其是字幕边缘发灰。

## 已知遗留

- **fp16 / 8-bit 不匹配**：`createPixelFormat()` 用 `kCGLPFAColorSize=64 + kCGLPFAColorFloat`，但 IOSurface 一直是 `kCVPixelFormatType_32BGRA`。FBO 内部 fp16 ↔ 8-bit 输出做了无谓转换；HDR / 10-bit 内容仍被截断到 8-bit。要真正利用 gpu-next 的 HDR tone-mapping，需把上层 API 扩展为可选 `kCVPixelFormatType_64RGBAHalf` 等，并验证 Flutter macOS embedder 接受 fp16 像素格式。
- **未启用 advanced_control**：当前 `_updateCallback` 无条件 render；启用 advanced_control 必须改为按 `mpv_render_context_update()` 的 `MPV_RENDER_UPDATE_FRAME` 位决定，并在 Flutter 实际上屏（需要 `CVDisplayLink`/`CADisplayLink` 桥接）时调用 `mpv_render_context_report_swap()`。属于跨 `VideoOutput` + `TextureHW` 的结构性改动。
- **OpenGL 已 deprecated**：长期路线是迁 Metal（`CVMetalTextureCache` + libplacebo Metal backend），但需要上游 mpv 暴露 `MPV_RENDER_API_TYPE_METAL`，目前未定义。
- **GL 上下文每帧 set/unset**：worker 是单线程，可让 worker 长期持有 `CGLContextObj`。但 `OpenGLHelpers` 里的静态 helper 也都自己 set+unset，全面切换需联动调整，目前未做。
- **`TextureGLContext` deinit 依赖 GL 上下文当前**：因为新增了 `glDeleteSync` 清理。`disposePixelBuffer()` 已先 `CGLSetCurrentContext`；如果将来其它路径释放 `TextureGLContext`，需保持同样契约。
