public class TextureGLContext {
  private let context: CGLContextObj
  public let frameBuffer: GLuint
  public let texture: CVOpenGLTexture
  public let pixelBuffer: CVPixelBuffer

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
    OpenGLHelpers.deletePixeBuffer(context, pixelBuffer)
    OpenGLHelpers.deleteTexture(context, texture)
    OpenGLHelpers.deleteFrameBuffer(context, frameBuffer)
  }
}
