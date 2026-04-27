import FlutterMacOS
import OpenGL.GL
import OpenGL.GL3

public class TextureHW: NSObject, FlutterTexture, ResizableTextureProtocol {
  public typealias UpdateCallback = () -> Void

  private let handle: OpaquePointer
  private let updateCallback: UpdateCallback
  private let pixelFormat: CGLPixelFormatObj
  private let context: CGLContextObj
  private let textureCache: CVOpenGLTextureCache
  private var renderContext: OpaquePointer?
  private var screenObserver: NSObjectProtocol?
  private var textureContexts = SwappableObjectManager<TextureGLContext>(
    objects: [],
    skipCheckArgs: true
  )

  init(
    handle: OpaquePointer,
    updateCallback: @escaping UpdateCallback
  ) {
    self.handle = handle
    self.updateCallback = updateCallback
    self.pixelFormat = OpenGLHelpers.createPixelFormat()
    self.context = OpenGLHelpers.createContext(pixelFormat)
    self.textureCache = OpenGLHelpers.createTextureCache(context, pixelFormat)

    super.init()

    self.initMPV()
    self.applyDisplayICCProfile()
    self.startObservingScreenChanges()
  }

  deinit {
    stopObservingScreenChanges()
    disposePixelBuffer()
    disposeMPV()
    OpenGLHelpers.deleteTextureCache(textureCache)
    OpenGLHelpers.deletePixelFormat(pixelFormat)

    // Deleting the context may cause potential RAM or VRAM memory leaks, as it
    // is used in the `deinit` method of the `TextureGLContext`.
    // Potential fix: use a counter, and delete it only when the counter reaches
    // zero
    OpenGLHelpers.deleteContext(context)
  }

  public func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    let textureContext = textureContexts.current
    if textureContext == nil {
      return nil
    }

    return Unmanaged.passRetained(textureContext!.pixelBuffer)
  }

  private func initMPV() {
    CGLSetCurrentContext(context)
    defer {
      OpenGLHelpers.checkError("initMPV")
      CGLSetCurrentContext(nil)
    }

    let api = UnsafeMutableRawPointer(
      mutating: (MPV_RENDER_API_TYPE_OPENGL as NSString).utf8String
    )
    let backend = UnsafeMutableRawPointer(
      mutating: ("gpu-next" as NSString).utf8String
    )
    var procAddress = mpv_opengl_init_params(
      get_proc_address: {
        (ctx, name) in
        return TextureHW.getProcAddress(ctx, name)
      },
      get_proc_address_ctx: nil
    )

    var params: [mpv_render_param] = withUnsafeMutableBytes(of: &procAddress) {
      procAddress in
      return [
        mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: api),
        mpv_render_param(type: MPV_RENDER_PARAM_BACKEND, data: backend),
        mpv_render_param(
          type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,
          data: procAddress.baseAddress.map {
            UnsafeMutableRawPointer($0)
          }
        ),
        mpv_render_param(),
      ]
    }

    MPVHelpers.checkError(
      mpv_render_context_create(&renderContext, handle, &params)
    )

    mpv_render_context_set_update_callback(
      renderContext,
      { (ctx) in
        let that = unsafeBitCast(ctx, to: TextureHW.self)
        DispatchQueue.main.async {
          that.updateCallback()
        }
      },
      UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
    )
  }

  private func disposeMPV() {
    CGLSetCurrentContext(context)
    defer {
      OpenGLHelpers.checkError("disposeMPV")
      CGLSetCurrentContext(nil)
    }

    mpv_render_context_set_update_callback(renderContext, nil, nil)
    mpv_render_context_free(renderContext)
  }

  // Push the current display's ICC profile to the gpu-next backend so the
  // colour pipeline targets the actual monitor instead of falling back to
  // generic sRGB. Without this, P3/HDR-capable displays receive incorrect
  // colour reproduction.
  private func applyDisplayICCProfile() {
    guard let renderContext else { return }

    // Tell mpv we are supplying the ICC ourselves; this also keeps the
    // injected profile from being cleared on the next options update.
    mpv_set_property_string(handle, "icc-profile-auto", "yes")

    guard let icc = NSScreen.main?.colorSpace?.iccProfileData else {
      return
    }
    let nsData = icc as NSData
    var byteArray = mpv_byte_array(
      data: UnsafeMutableRawPointer(mutating: nsData.bytes),
      size: nsData.length
    )
    withUnsafeMutablePointer(to: &byteArray) { ptr in
      _ = mpv_render_context_set_parameter(
        renderContext,
        mpv_render_param(
          type: MPV_RENDER_PARAM_ICC_PROFILE,
          data: UnsafeMutableRawPointer(ptr)
        )
      )
    }
  }

  private func startObservingScreenChanges() {
    // Re-inject the ICC profile when the screen layout changes (display
    // hot-plug, resolution change, dragging the window between displays, ...).
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.applyDisplayICCProfile()
    }
  }

  private func stopObservingScreenChanges() {
    if let observer = screenObserver {
      NotificationCenter.default.removeObserver(observer)
      screenObserver = nil
    }
  }

  public func resize(_ size: CGSize) {
    if size.width == 0 || size.height == 0 {
      return
    }

    NSLog("TextureGL: resize: \(size.width)x\(size.height)")
    createPixelBuffer(size)
  }

  private func createPixelBuffer(_ size: CGSize) {
    disposePixelBuffer()

    textureContexts.reinit(
      objects: [
        TextureGLContext(
          context: context,
          textureCache: textureCache,
          size: size
        ),
        TextureGLContext(
          context: context,
          textureCache: textureCache,
          size: size
        ),
        TextureGLContext(
          context: context,
          textureCache: textureCache,
          size: size
        ),
      ],
      skipCheckArgs: true
    )
  }

  private func disposePixelBuffer() {
    // The GL context must be current before releasing TextureGLContext
    // instances, since their deinit may need to delete GL fence sync objects
    // bound to the context.
    CGLSetCurrentContext(context)
    defer {
      CGLSetCurrentContext(nil)
    }

    textureContexts.reinit(objects: [], skipCheckArgs: true)

    // `glDeleteTextures` alone does not release the IOSurface backing the
    // CVOpenGLTexture; the texture cache keeps an internal reference until
    // it is flushed. Without this call, every resize accumulates retained
    // IOSurfaces until the cache itself is destroyed.
    CVOpenGLTextureCacheFlush(textureCache, 0)
  }

  public func render(_ size: CGSize) {
    let textureContext = textureContexts.nextAvailable()
    if textureContext == nil {
      return
    }

    CGLSetCurrentContext(context)
    defer {
      OpenGLHelpers.checkError("render")
      CGLSetCurrentContext(nil)
    }

    // Block until the GPU has finished writing to this slot during its
    // previous turn, otherwise Flutter could sample a half-written IOSurface.
    // Triple buffering means each slot only waits roughly one frame later, so
    // the GPU still pipelines work without serialization.
    textureContext!.waitAndClearFence()

    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), textureContext!.frameBuffer)
    defer {
      glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
    }

    var fbo = mpv_opengl_fbo(
      fbo: Int32(textureContext!.frameBuffer),
      w: Int32(size.width),
      h: Int32(size.height),
      internal_format: 0
    )
    let fboPtr = withUnsafeMutablePointer(to: &fbo) { $0 }

    var params: [mpv_render_param] = [
      mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fboPtr),
      mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
    ]
    mpv_render_context_render(renderContext, &params)

    glFlush()

    // Insert a fence representing the GPU completion of this render so the
    // next reuse of this slot can wait on it before issuing new GL work.
    textureContext!.insertFence()

    textureContexts.pushAsReady(textureContext!)
  }

  static private func getProcAddress(
    _ ctx: UnsafeMutableRawPointer?,
    _ name: UnsafePointer<Int8>?
  ) -> UnsafeMutableRawPointer? {
    let symbol: CFString = CFStringCreateWithCString(
      kCFAllocatorDefault,
      name,
      kCFStringEncodingASCII
    )
    let indentifier = CFBundleGetBundleWithIdentifier(
      "com.apple.opengl" as CFString
    )
    let addr = CFBundleGetFunctionPointerForName(indentifier, symbol)

    if addr == nil {
      NSLog("Cannot get OpenGL function pointer!")
    }
    return addr
  }
}
