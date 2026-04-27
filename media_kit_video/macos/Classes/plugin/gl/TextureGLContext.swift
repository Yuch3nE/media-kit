import OpenGL.GL
import OpenGL.GL3

public class TextureGLContext {
  private let context: CGLContextObj
  public let frameBuffer: GLuint
  public let texture: CVOpenGLTexture
  public let pixelBuffer: CVPixelBuffer

  // GL fence inserted after the previous render targeting this slot. The next
  // reuse must wait on it before issuing new GL commands, so that Flutter is
  // never handed a CVPixelBuffer whose backing IOSurface is still being
  // written to by the GPU.
  private var fence: GLsync?

  init(
    context: CGLContextObj,
    textureCache: CVOpenGLTextureCache,
    size: CGSize
  ) {
    self.context = context

    self.pixelBuffer = OpenGLHelpers.createPixelBuffer(size)

    self.texture = OpenGLHelpers.createTexture(
      textureCache,
      pixelBuffer
    )

    self.frameBuffer = OpenGLHelpers.createFrameBuffer(
      context: context,
      texture: texture,
      size: size
    )
  }

  deinit {
    // The current GL context must be set by the caller; this method is invoked
    // from the worker thread that owns the context.
    if let f = fence {
      glDeleteSync(f)
      fence = nil
    }

    OpenGLHelpers.deletePixeBuffer(context, pixelBuffer)
    OpenGLHelpers.deleteTexture(context, texture)
    OpenGLHelpers.deleteFrameBuffer(context, frameBuffer)
  }

  // Block until the GPU work pushed by the previous render targeting this slot
  // has completed. Caller must have the GL context current.
  public func waitAndClearFence() {
    guard let f = fence else { return }
    glClientWaitSync(
      f,
      GLbitfield(GL_SYNC_FLUSH_COMMANDS_BIT),
      GLuint64.max
    )
    glDeleteSync(f)
    fence = nil
  }

  // Insert a fence representing the GPU completion of all previously issued
  // commands. Caller must have the GL context current.
  public func insertFence() {
    if let f = fence {
      glDeleteSync(f)
    }
    fence = glFenceSync(GLenum(GL_SYNC_GPU_COMMANDS_COMPLETE), 0)
  }
}
