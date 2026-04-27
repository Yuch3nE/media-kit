import FlutterMacOS
import Metal
import CoreVideo
import AppKit

// TextureVK: macOS FlutterTexture that drives mpv's Vulkan render backend
// (MPV_RENDER_API_TYPE_VULKAN) over MoltenVK, producing CVPixelBuffer frames
// for Flutter via an IOSurface-backed MTLTexture.
//
// Pipeline per frame:
//   1. Pick an idle slot (triple-buffered) holding (CVPixelBuffer + IOSurface
//      + MTLTexture + VkImage import + VkSemaphore).
//   2. mpv_render_context_render with MPV_RENDER_PARAM_VK_IMAGE pointing at
//      the slot's VkImage and signal_semaphore set to the slot's VkSemaphore.
//   3. mk_vk_wait_semaphore_blocking on the semaphore so we know the GPU
//      finished writing the MTLTexture.
//   4. Push slot to the "ready" queue; copyPixelBuffer returns its
//      CVPixelBuffer next time Flutter samples.
//
// Cross-API sync is currently the simple blocking variant (vkQueueWaitIdle).
// A v2 will replace it with VK_KHR_external_semaphore_metal -> MTLSharedEvent
// so the Metal compositor can wait async on its own queue.

public final class TextureVK: NSObject, FlutterTexture, ResizableTextureProtocol {
    public typealias UpdateCallback = () -> Void

    private struct Slot {
        let pixelBuffer: CVPixelBuffer
        let mtlTexture:  MTLTexture
        let vkImage:     OpaquePointer  // MKVulkanImage*
        let vkImageHandle: UInt64       // VkImage handle for mpv
        let vkSemaphore:   UInt64       // VkSemaphore handle for mpv
        let format:        UInt32
        let usage:         UInt32
        let width:         UInt32
        let height:        UInt32
    }

    private let handle: OpaquePointer
    private let updateCallback: UpdateCallback
    private let mtlDevice: MTLDevice

    private let vkContext: OpaquePointer  // MKVulkanContext*
    private var renderContext: OpaquePointer?
    private var slots: SwappableObjectManager<SlotBox> =
        SwappableObjectManager<SlotBox>(objects: [], skipCheckArgs: true)
    // Mirror list of all slots so we can free them on resize/teardown without
    // depending on SwappableObjectManager internals.
    private var ownedSlots: [SlotBox] = []

    // --- HDR / colorspace pass-through state --------------------------------
    // What we tell mpv the host surface looks like (target state). Updated on
    // screen change. Strings use mpv's color option naming (see render_vk.h).
    private var hostSurfacePrimaries: String = "display-p3"
    private var hostSurfaceTransfer:  String = "srgb"
    private var hostSurfaceMaxLuma:   Float  = 0.0  // 0 = unknown
    private var hostSurfaceMinLuma:   Float  = 0.0
    private var screenObserver: NSObjectProtocol?

    // Wraps Slot in a class so SwappableObjectManager (which expects AnyObject)
    // can hold it.
    final class SlotBox {
        let inner: Slot
        init(_ s: Slot) { self.inner = s }
    }

    init?(handle: OpaquePointer, updateCallback: @escaping UpdateCallback) {
        self.handle = handle
        self.updateCallback = updateCallback

        guard let device = MTLCreateSystemDefaultDevice() else {
            NSLog("TextureVK: no MTLDevice")
            return nil
        }
        self.mtlDevice = device

        guard let ctx = mk_vk_context_create() else {
            NSLog("TextureVK: failed to create Vulkan context (MoltenVK missing?)")
            return nil
        }
        self.vkContext = OpaquePointer(ctx)

        super.init()

        if !initMPV() {
            mk_vk_context_destroy(UnsafeMutableRawPointer(vkContext)
                .assumingMemoryBound(to: MKVulkanContext.self))
            return nil
        }
        refreshHostSurfaceFromCurrentScreen()
        startObservingScreenChanges()
    }

    deinit {
        stopObservingScreenChanges()
        disposeSlots()
        if let rc = renderContext {
            mpv_render_context_set_update_callback(rc, nil, nil)
            mpv_render_context_free(rc)
        }
        mk_vk_context_destroy(UnsafeMutableRawPointer(vkContext)
            .assumingMemoryBound(to: MKVulkanContext.self))
    }

    // MARK: FlutterTexture

    public func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        guard let box = slots.current else { return nil }
        return Unmanaged.passRetained(box.inner.pixelBuffer)
    }

    // MARK: ResizableTextureProtocol

    public func resize(_ size: CGSize) {
        if size.width <= 0 || size.height <= 0 { return }
        createSlots(width: Int(size.width), height: Int(size.height))
    }

    public func render(_ size: CGSize) {
        guard let rc = renderContext, let box = slots.nextAvailable() else { return }

        var image = mpv_vulkan_image()
        image.image           = box.inner.vkImageHandle
        image.width           = box.inner.width
        image.height          = box.inner.height
        image.format          = box.inner.format
        image.usage           = box.inner.usage
        image.aspect          = 0  // default = COLOR
        image.in_layout       = 0  // VK_IMAGE_LAYOUT_UNDEFINED
        image.in_qf           = 0  // VK_QUEUE_FAMILY_IGNORED
        image.out_layout      = 5  // VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
        image.out_qf          = 0
        image.wait_semaphore  = 0
        image.wait_value      = 0
        image.signal_semaphore = box.inner.vkSemaphore
        image.signal_value    = 0

        // Surface description. mpv consumes these as host-target hints via the
        // libmpv_gpu_next_context_vk backend (see render_vk.h doc).
        let primCStr = (hostSurfacePrimaries as NSString).utf8String
        let trcCStr  = (hostSurfaceTransfer  as NSString).utf8String
        image.surface_primaries = primCStr
        image.surface_transfer  = trcCStr
        image.surface_min_luma  = hostSurfaceMinLuma
        image.surface_max_luma  = hostSurfaceMaxLuma
        image.surface_max_cll   = 0
        image.surface_max_fall  = 0

        var imageMut = image
        withUnsafeMutablePointer(to: &imageMut) { imgPtr in
            var params: [mpv_render_param] = [
                mpv_render_param(type: MPV_RENDER_PARAM_VK_IMAGE,
                                 data: UnsafeMutableRawPointer(imgPtr)),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            mpv_render_context_render(rc, &params)
        }

        // Wait until the GPU finishes writing into the MTLTexture so Flutter
        // can sample without tearing. v2: replace with MTLSharedEvent wait.
        mk_vk_wait_semaphore_blocking(
            UnsafeMutableRawPointer(vkContext)
                .assumingMemoryBound(to: MKVulkanContext.self),
            box.inner.vkSemaphore)

        // After the frame is final, ask mpv what color space it actually
        // produced and stamp the matching CV attachments onto the pixel
        // buffer so Core Animation / Flutter color-manage correctly.
        applyColorspaceHintToPixelBuffer(box.inner.pixelBuffer)

        slots.pushAsReady(box)
    }

    // MARK: internals

    private func initMPV() -> Bool {
        let api = UnsafeMutableRawPointer(
            mutating: (MPV_RENDER_API_TYPE_VULKAN as NSString).utf8String)
        let backend = UnsafeMutableRawPointer(
            mutating: ("gpu-next" as NSString).utf8String)

        var devExtCount: size_t = 0
        let devExtsPtr = mk_vk_context_device_extensions(
            UnsafeMutableRawPointer(vkContext)
                .assumingMemoryBound(to: MKVulkanContext.self),
            &devExtCount)

        var initParams = mpv_vulkan_init_params(
            instance:                  mk_vk_context_instance(UnsafeMutableRawPointer(vkContext).assumingMemoryBound(to: MKVulkanContext.self)),
            phys_device:               mk_vk_context_phys_device(UnsafeMutableRawPointer(vkContext).assumingMemoryBound(to: MKVulkanContext.self)),
            device:                    mk_vk_context_device(UnsafeMutableRawPointer(vkContext).assumingMemoryBound(to: MKVulkanContext.self)),
            queue_family_index:        mk_vk_context_queue_family_index(UnsafeMutableRawPointer(vkContext).assumingMemoryBound(to: MKVulkanContext.self)),
            queue_index:               0,
            queue_count:               mk_vk_context_queue_count(UnsafeMutableRawPointer(vkContext).assumingMemoryBound(to: MKVulkanContext.self)),
            get_proc_addr:             mk_vk_context_get_proc_addr(UnsafeMutableRawPointer(vkContext).assumingMemoryBound(to: MKVulkanContext.self)),
            enabled_features:          mk_vk_context_features(UnsafeMutableRawPointer(vkContext).assumingMemoryBound(to: MKVulkanContext.self)),
            lock_queue:                mk_vk_context_lock_queue,
            unlock_queue:              mk_vk_context_unlock_queue,
            queue_ctx:                 UnsafeMutableRawPointer(vkContext),
            enabled_device_extensions: devExtsPtr,
            num_enabled_device_extensions: devExtCount,
            enabled_instance_extensions: nil,
            num_enabled_instance_extensions: 0)

        return withUnsafeMutablePointer(to: &initParams) { ipPtr -> Bool in
            var params: [mpv_render_param] = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: api),
                mpv_render_param(type: MPV_RENDER_PARAM_BACKEND, data: backend),
                mpv_render_param(type: MPV_RENDER_PARAM_VULKAN_INIT_PARAMS,
                                 data: UnsafeMutableRawPointer(ipPtr)),
                mpv_render_param(),
            ]
            let rc = mpv_render_context_create(&renderContext, handle, &params)
            if rc < 0 {
                NSLog("TextureVK: mpv_render_context_create failed: \(rc)")
                return false
            }
            mpv_render_context_set_update_callback(
                renderContext,
                { (ctx) in
                    let that = unsafeBitCast(ctx, to: TextureVK.self)
                    DispatchQueue.main.async { that.updateCallback() }
                },
                UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
            return true
        }
    }

    private func createSlots(width: Int, height: Int) {
        disposeSlots()

        var built: [SlotBox] = []
        for _ in 0..<3 {
            guard let s = makeSlot(width: width, height: height) else {
                NSLog("TextureVK: slot creation failed; aborting resize.")
                disposeSlots()
                return
            }
            built.append(SlotBox(s))
        }
        slots.reinit(objects: built, skipCheckArgs: true)
        ownedSlots = built
    }

    private func makeSlot(width: Int, height: Int) -> Slot? {
        // 1. CVPixelBuffer with IOSurface backing, BGRA8.
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pb: CVPixelBuffer?
        let s = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                    kCVPixelFormatType_32BGRA,
                                    attrs as CFDictionary, &pb)
        guard s == kCVReturnSuccess, let pixelBuffer = pb,
              let iosurface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
            NSLog("TextureVK: CVPixelBufferCreate / IOSurface failed (\(s)).")
            return nil
        }

        // 2. MTLTexture from IOSurface.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead, .shaderWrite]
        desc.storageMode = .shared
        guard let tex = mtlDevice.makeTexture(descriptor: desc, iosurface: iosurface, plane: 0) else {
            NSLog("TextureVK: MTLDevice.makeTexture failed.")
            return nil
        }

        // 3. Import MTLTexture as VkImage.
        var vkFormat: UInt32 = 0
        var vkUsage:  UInt32 = 0
        let texPtr = Unmanaged.passUnretained(tex).toOpaque()
        guard let vkImg = mk_vk_image_import_mtl(
            UnsafeMutableRawPointer(vkContext).assumingMemoryBound(to: MKVulkanContext.self),
            texPtr, UInt32(width), UInt32(height), &vkFormat, &vkUsage)
        else {
            NSLog("TextureVK: mk_vk_image_import_mtl failed.")
            return nil
        }

        // 4. Per-slot binary semaphore.
        let sem = mk_vk_semaphore_create(
            UnsafeMutableRawPointer(vkContext).assumingMemoryBound(to: MKVulkanContext.self))
        if sem == 0 {
            mk_vk_image_destroy(UnsafeMutableRawPointer(vkContext)
                .assumingMemoryBound(to: MKVulkanContext.self), vkImg)
            return nil
        }

        return Slot(pixelBuffer: pixelBuffer, mtlTexture: tex,
                    vkImage: OpaquePointer(vkImg),
                    vkImageHandle: mk_vk_image_handle(vkImg),
                    vkSemaphore: sem,
                    format: vkFormat, usage: vkUsage,
                    width: UInt32(width), height: UInt32(height))
    }

    private func disposeSlots() {
        let cur = ownedSlots
        ownedSlots = []
        slots.reinit(objects: [], skipCheckArgs: true)
        let ctxPtr = UnsafeMutableRawPointer(vkContext)
            .assumingMemoryBound(to: MKVulkanContext.self)
        for box in cur {
            mk_vk_semaphore_destroy(ctxPtr, box.inner.vkSemaphore)
            mk_vk_image_destroy(ctxPtr,
                UnsafeMutablePointer<MKVulkanImage>(box.inner.vkImage))
        }
    }

    // MARK: - HDR / colorspace pass-through ------------------------------------

    private func startObservingScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshHostSurfaceFromCurrentScreen()
        }
    }

    private func stopObservingScreenChanges() {
        if let o = screenObserver {
            NotificationCenter.default.removeObserver(o)
            screenObserver = nil
        }
    }

    // Probe the current main screen's color profile + EDR capability and turn
    // it into mpv-compatible (primaries, transfer, luma) tuples that we feed
    // back into the Vulkan render backend through MPV_RENDER_PARAM_VK_TARGET_STATE.
    private func refreshHostSurfaceFromCurrentScreen() {
        guard let screen = NSScreen.main else { return }

        // Primaries: rough heuristic based on the screen's NSColorSpace name.
        // mpv accepts the canonical name strings listed in render_vk.h.
        var primaries = "display-p3"
        if let cs = screen.colorSpace, let name = cs.localizedName {
            let lc = name.lowercased()
            if lc.contains("rec") && lc.contains("2020") {
                primaries = "bt.2020"
            } else if lc.contains("p3") {
                primaries = "display-p3"
            } else if lc.contains("srgb") || lc.contains("rec") || lc.contains("709") {
                primaries = "bt.709"
            }
        }

        // Transfer: macOS in EDR mode signals capability via
        // maximumExtendedDynamicRangeColorComponentValue. Treat > 1.0 as HDR
        // and request PQ; otherwise stay on sRGB so SDR content does not get
        // tone-mapped unnecessarily.
        let maxEDR = Float(screen.maximumExtendedDynamicRangeColorComponentValue)
        let transfer = maxEDR > 1.0 ? "pq" : "srgb"
        let maxLuma: Float = maxEDR > 1.0 ? maxEDR * 100.0 : 0.0
        let minLuma: Float = maxEDR > 1.0 ? 0.001 : 0.0

        hostSurfacePrimaries = primaries
        hostSurfaceTransfer  = transfer
        hostSurfaceMaxLuma   = maxLuma
        hostSurfaceMinLuma   = minLuma

        publishTargetStateToMPV()
    }

    // Push the current host surface description into mpv proactively (not
    // tied to a particular VkImage) so the colorspace hint can be queried
    // before the first render call.
    private func publishTargetStateToMPV() {
        guard let rc = renderContext else { return }

        var image = mpv_vulkan_image()
        // Only the surface description fields are read by VK_TARGET_STATE.
        image.format = UInt32(VK_FORMAT_B8G8R8A8_UNORM_VALUE)
        image.surface_primaries = (hostSurfacePrimaries as NSString).utf8String
        image.surface_transfer  = (hostSurfaceTransfer  as NSString).utf8String
        image.surface_min_luma  = hostSurfaceMinLuma
        image.surface_max_luma  = hostSurfaceMaxLuma

        withUnsafeMutablePointer(to: &image) { ptr in
            _ = mpv_render_context_set_parameter(
                rc,
                mpv_render_param(type: MPV_RENDER_PARAM_VK_TARGET_STATE,
                                 data: UnsafeMutableRawPointer(ptr)))
        }
    }

    // After each frame, ask mpv which colorspace it actually wrote and stamp
    // matching CV attachments onto the pixel buffer Flutter will sample.
    // Without this, Core Animation defaults to assuming sRGB and HDR / wide
    // gamut frames render with wrong colors.
    private func applyColorspaceHintToPixelBuffer(_ pb: CVPixelBuffer) {
        guard let rc = renderContext else { return }

        var hint = mpv_vulkan_colorspace_hint()
        let rcv = withUnsafeMutablePointer(to: &hint) { hp -> Int32 in
            mpv_render_context_get_info(
                rc,
                mpv_render_param(type: MPV_RENDER_PARAM_VK_COLORSPACE_HINT,
                                 data: UnsafeMutableRawPointer(hp)))
        }
        guard rcv >= 0, hint.state.rawValue == MPV_VULKAN_COLORSPACE_HINT_SET.rawValue,
              let primCStr = hint.primaries, let trcCStr = hint.transfer
        else { return }

        let primaries = String(cString: primCStr)
        let transfer  = String(cString: trcCStr)

        if let cvPrim = TextureVK.cvPrimaries(forName: primaries) {
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey,
                                  cvPrim, .shouldPropagate)
        }
        if let cvTrc = TextureVK.cvTransfer(forName: transfer) {
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey,
                                  cvTrc, .shouldPropagate)
        }
        // Default YCbCr matrix is irrelevant for RGB pixel buffers but Core
        // Image still consults the key; supply the matching primaries-derived
        // matrix to avoid a "missing matrix" warning.
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                              .shouldPropagate)
    }

    private static func cvPrimaries(forName name: String) -> CFString? {
        switch name {
        case "bt.709":      return kCVImageBufferColorPrimaries_ITU_R_709_2
        case "display-p3":  return kCVImageBufferColorPrimaries_P3_D65
        case "bt.2020":     return kCVImageBufferColorPrimaries_ITU_R_2020
        case "smpte-431", "dci-p3": return kCVImageBufferColorPrimaries_DCI_P3
        case "bt.601-525":  return kCVImageBufferColorPrimaries_SMPTE_C
        case "bt.601-625":  return kCVImageBufferColorPrimaries_EBU_3213
        default:            return nil
        }
    }

    private static func cvTransfer(forName name: String) -> CFString? {
        switch name {
        case "bt.1886", "bt.709":
            return kCVImageBufferTransferFunction_ITU_R_709_2
        case "srgb":
            return kCVImageBufferTransferFunction_sRGB
        case "linear":
            return kCVImageBufferTransferFunction_Linear
        case "pq":
            return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case "hlg":
            return kCVImageBufferTransferFunction_ITU_R_2100_HLG
        case "gamma2.2":
            return kCVImageBufferTransferFunction_UseGamma
        default:
            return nil
        }
    }
}

// VK_FORMAT_B8G8R8A8_UNORM = 44 (we hardcode rather than depend on
// vulkan_core.h being visible to Swift).
private let VK_FORMAT_B8G8R8A8_UNORM_VALUE: Int32 = 44
