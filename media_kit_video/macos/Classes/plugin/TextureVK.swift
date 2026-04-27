import FlutterMacOS
import Metal
import CoreVideo
import AppKit

#if MEDIA_KIT_ENABLE_VULKAN

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

    fileprivate struct Slot {
        let pixelBuffer: CVPixelBuffer
        let mtlTexture:  MTLTexture
        let vkImage:     OpaquePointer  // MKVulkanImage*
        let vkImageHandle: UInt64       // VkImage handle for mpv
        let vkSemaphore:   UInt64       // VkSemaphore handle for mpv
        // Async cross-API sync. When non-nil, vkSemaphore is a timeline
        // semaphore backed by the same MTLSharedEvent and we drive it via
        // monotonically increasing payload values.
        let mtlEvent:      MTLSharedEvent?
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

    // --- Async cross-API sync (MTLSharedEvent + Vulkan timeline semaphore) --
    private var asyncSyncSupported: Bool = false
    // Monotonic counter used as VkSemaphore signal_value & MTLSharedEvent
    // signaled value. Bumped per render call. Starts at 1 (0 is reserved by
    // render_vk.h to mean "binary semaphore").
    private var nextSignalValue: UInt64 = 0
    // Process-wide singleton. Each MTLSharedEventListener spins up its own
    // dispatch queue / runloop; sharing avoids paying that cost per player.
    private static let sharedEventListener = MTLSharedEventListener()

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
    fileprivate final class SlotBox {
        fileprivate let inner: Slot
        fileprivate init(_ s: Slot) { self.inner = s }
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
        self.vkContext = ctx

        super.init()

        if !initMPV() {
            mk_vk_context_destroy(vkContext)
            return nil
        }
        let reportedAsyncSyncSupport = mk_vk_supports_metal_event_sync(vkContext)
        // MoltenVK/libplacebo currently reports a usable Vulkan device here,
        // but the MTLSharedEvent-backed timeline path does not drive the
        // render loop reliably yet. Keep the simpler blocking semaphore path
        // until the async interop is validated end-to-end on macOS.
        asyncSyncSupported = false
        if reportedAsyncSyncSupport {
            NSLog("TextureVK: disabling MTLSharedEvent timeline sync on macOS; falling back to vkQueueWaitIdle blocking sync.")
        } else {
            NSLog("TextureVK: falling back to vkQueueWaitIdle blocking sync.")
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
        mk_vk_context_destroy(vkContext)
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

        // Pick a fresh signal value for timeline mode; binary mode uses 0.
        var signalValue: UInt64 = 0
        if box.inner.mtlEvent != nil {
            nextSignalValue &+= 1
            signalValue = nextSignalValue
        }

        var image = mpv_vulkan_image()
        image.image           = box.inner.vkImageHandle
        image.width           = box.inner.width
        image.height          = box.inner.height
        image.format          = box.inner.format
        image.usage           = box.inner.usage
        // VK_IMAGE_ASPECT_COLOR_BIT = 0x1. Spec allows 0 here, but at least
        // some libplacebo paths fast-path on a non-zero aspect mask, so be
        // explicit.
        image.aspect          = 0x1
        image.in_layout       = 0  // VK_IMAGE_LAYOUT_UNDEFINED
        // VK_QUEUE_FAMILY_EXTERNAL = (~0u - 1) = 0xFFFFFFFE.
        // The image is backed by an MTLTexture (a non-Vulkan API), so per
        // render_vk.h we must mark both the inbound and outbound queue
        // family as EXTERNAL. Without this, MoltenVK does not emit the
        // ownership-release barrier and the rendered contents never get
        // flushed back into the underlying IOSurface -> black frame in
        // Flutter even though every Vulkan call returns success.
        image.in_qf           = 0xFFFFFFFE
        image.out_layout      = 5  // VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
        image.out_qf          = 0xFFFFFFFE
        image.wait_semaphore  = 0
        image.wait_value      = 0
        image.signal_semaphore = box.inner.vkSemaphore
        image.signal_value    = signalValue

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
        var renderRc: Int32 = 0
        withUnsafeMutablePointer(to: &imageMut) { imgPtr in
            var params: [mpv_render_param] = [
                mpv_render_param(type: MPV_RENDER_PARAM_VK_IMAGE,
                                 data: UnsafeMutableRawPointer(imgPtr)),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            renderRc = mpv_render_context_render(rc, &params)
        }
        if renderRc < 0 {
            // Once-per-second cap on the failure log so a broken pipeline
            // doesn't drown unified logs.
            let now = Date().timeIntervalSinceReferenceDate
            if now - lastRenderFailLogAt > 1.0 {
                lastRenderFailLogAt = now
                let errStr = mpv_error_string(renderRc).map { String(cString: $0) } ?? "?"
                NSLog("TextureVK: mpv_render_context_render rc=\(renderRc) (\(errStr))")
            }
        }

        applyColorspaceHintToPixelBuffer(box.inner.pixelBuffer)

        if let mtlEvent = box.inner.mtlEvent {
            // Async path: register a listener that fires when the GPU has
            // signalled the MTLSharedEvent (which is the same payload that
            // mpv signals on the Vk side via timeline semaphore). The worker
            // thread is freed immediately while the slot publishes itself
            // once the GPU is genuinely done.
            mtlEvent.notify(TextureVK.sharedEventListener, atValue: signalValue) {
                [weak self] (_: MTLSharedEvent, _: UInt64) in
                guard let self = self else { return }
                self.slots.pushAsReady(box)
                // FlutterTextureRegistry / updateCallback consumers expect
                // main-thread invocation; the shared-event listener queue is
                // a system-provided concurrent queue.
                DispatchQueue.main.async { self.updateCallback() }
            }
        } else {
            // Blocking fallback: vkQueueWaitIdle on a tiny submission.
            mk_vk_wait_semaphore_blocking(vkContext, box.inner.vkSemaphore)
            slots.pushAsReady(box)
            if !firstFramePublished {
                firstFramePublished = true
                NSLog("TextureVK: first frame published (\(box.inner.width)x\(box.inner.height), fmt=\(box.inner.format)).")
            }
        }
    }

    private var lastRenderFailLogAt: TimeInterval = 0
    private var firstFramePublished: Bool = false

    // MARK: internals

    private func initMPV() -> Bool {
        let api = UnsafeMutableRawPointer(
            mutating: (MPV_RENDER_API_TYPE_VULKAN as NSString).utf8String)
        let backend = UnsafeMutableRawPointer(
            mutating: ("gpu-next" as NSString).utf8String)

        var devExtCount: size_t = 0
        let devExtsPtr = mk_vk_context_device_extensions(vkContext, &devExtCount)

        var initParams = mpv_vulkan_init_params(
            instance:                  mk_vk_context_instance(vkContext),
            phys_device:               mk_vk_context_phys_device(vkContext),
            device:                    mk_vk_context_device(vkContext),
            queue_family_index:        mk_vk_context_queue_family_index(vkContext),
            queue_count:               mk_vk_context_queue_count(vkContext),
            get_proc_addr:             mk_vk_context_get_proc_addr(vkContext),
            enabled_features:          mk_vk_context_features(vkContext),
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
                let errorText = mpv_error_string(rc).map { String(cString: $0) } ?? "unknown"
                NSLog("TextureVK: mpv_render_context_create failed: \(rc) (\(errorText))")
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
            vkContext,
            texPtr, UInt32(width), UInt32(height), &vkFormat, &vkUsage)
        else {
            NSLog("TextureVK: mk_vk_image_import_mtl failed.")
            return nil
        }

        // 4. Per-slot semaphore. Prefer MTLSharedEvent-backed timeline sem
        //    (async sync); fall back to a plain binary semaphore if the
        //    device cannot import Metal events.
        var mtlEvent: MTLSharedEvent? = nil
        var sem: UInt64 = 0
        if asyncSyncSupported,
           let ev = mtlDevice.makeSharedEvent() {
            let evPtr = Unmanaged.passUnretained(ev).toOpaque()
            sem = mk_vk_semaphore_import_mtl_event(vkContext, evPtr)
            if sem != 0 {
                mtlEvent = ev
            }
        }
        if sem == 0 {
            sem = mk_vk_semaphore_create(vkContext)
        }
        if sem == 0 {
            mk_vk_image_destroy(vkContext, vkImg)
            return nil
        }

        return Slot(pixelBuffer: pixelBuffer, mtlTexture: tex,
                    vkImage: vkImg,
                    vkImageHandle: mk_vk_image_handle(vkImg),
                    vkSemaphore: sem,
                    mtlEvent: mtlEvent,
                    format: vkFormat, usage: vkUsage,
                    width: UInt32(width), height: UInt32(height))
    }

    private func disposeSlots() {
        let cur = ownedSlots
        ownedSlots = []
        slots.reinit(objects: [], skipCheckArgs: true)
        for box in cur {
            mk_vk_semaphore_destroy(vkContext, box.inner.vkSemaphore)
            mk_vk_image_destroy(vkContext, box.inner.vkImage)
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

        // Primaries: identify by CGColorSpace.name CFString comparison rather
        // than localizedName (which varies by locale and OS version). Falls
        // back to display-p3 since that is the de-facto Apple wide-gamut
        // baseline.
        var primaries = "display-p3"
        if let cgcs = screen.colorSpace?.cgColorSpace,
           let name = cgcs.name as String? {
            switch name as CFString {
            case CGColorSpace.itur_2020,
                 CGColorSpace.itur_2020_PQ,
                 CGColorSpace.itur_2020_HLG:
                primaries = "bt.2020"
            case CGColorSpace.displayP3,
                 CGColorSpace.displayP3_PQ,
                 CGColorSpace.displayP3_HLG,
                 CGColorSpace.dcip3:
                primaries = "display-p3"
            case CGColorSpace.sRGB,
                 CGColorSpace.linearSRGB,
                 CGColorSpace.extendedSRGB,
                 CGColorSpace.itur_709:
                primaries = "bt.709"
            default:
                break
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

        // HDR static metadata: required by Core Animation EDR path. We
        // encode H.265 SEI-style blobs and attach them only when mpv tells
        // us the frame is actually HDR (PQ/HLG transfer with non-zero
        // luminance), otherwise SDR clips would carry stale HDR hints.
        let isHDR = (transfer == "pq" || transfer == "hlg") &&
                    (hint.max_luma > 0)
        if isHDR {
            if let mdcv = TextureVK.makeMasteringDisplayCVData(
                primaries: primaries,
                minLuma: hint.min_luma,
                maxLuma: hint.max_luma) {
                CVBufferSetAttachment(pb,
                    kCVImageBufferMasteringDisplayColorVolumeKey,
                    mdcv, .shouldPropagate)
            }
            if hint.max_cll > 0 || hint.max_fall > 0 {
                let cll = TextureVK.makeContentLightLevelCVData(
                    maxCLL: hint.max_cll, maxFALL: hint.max_fall)
                CVBufferSetAttachment(pb,
                    kCVImageBufferContentLightLevelInfoKey,
                    cll, .shouldPropagate)
            }
        }
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

    // CIE xy chromaticities per primaries spec. (x, y) for R, G, B, then white
    // point. Values match libplacebo's pl_raw_primaries_get / ITU specs.
    private static func chromaticities(forName name: String)
        -> (rx: Double, ry: Double, gx: Double, gy: Double,
            bx: Double, by: Double, wx: Double, wy: Double)?
    {
        switch name {
        case "bt.709":
            return (0.640, 0.330, 0.300, 0.600, 0.150, 0.060, 0.3127, 0.3290)
        case "display-p3":
            return (0.680, 0.320, 0.265, 0.690, 0.150, 0.060, 0.3127, 0.3290)
        case "bt.2020":
            return (0.708, 0.292, 0.170, 0.797, 0.131, 0.046, 0.3127, 0.3290)
        case "smpte-431", "dci-p3":
            return (0.680, 0.320, 0.265, 0.690, 0.150, 0.060, 0.3140, 0.3510)
        default:
            return nil
        }
    }

    // H.265 mastering_display_colour_volume SEI payload, big-endian, 24 bytes:
    //   display_primaries_x[3] (G,B,R) uint16, units of 0.00002
    //   display_primaries_y[3] (G,B,R) uint16, units of 0.00002
    //   white_point_x          uint16, units of 0.00002
    //   white_point_y          uint16, units of 0.00002
    //   max_display_mastering_luminance uint32, units of 0.0001 cd/m^2
    //   min_display_mastering_luminance uint32, units of 0.0001 cd/m^2
    // This is the exact byte layout that
    // kCVImageBufferMasteringDisplayColorVolumeKey expects on Apple platforms.
    private static func makeMasteringDisplayCVData(primaries: String,
                                                   minLuma: Float,
                                                   maxLuma: Float) -> CFData?
    {
        guard let xy = chromaticities(forName: primaries) else { return nil }

        var bytes = [UInt8]()
        bytes.reserveCapacity(24)

        func appendU16BE(_ v: UInt16) {
            bytes.append(UInt8(v >> 8))
            bytes.append(UInt8(v & 0xFF))
        }
        func appendU32BE(_ v: UInt32) {
            bytes.append(UInt8((v >> 24) & 0xFF))
            bytes.append(UInt8((v >> 16) & 0xFF))
            bytes.append(UInt8((v >> 8) & 0xFF))
            bytes.append(UInt8(v & 0xFF))
        }
        func toUnit(_ v: Double) -> UInt16 {
            let scaled = (v / 0.00002).rounded()
            return UInt16(max(0, min(scaled, Double(UInt16.max))))
        }
        func toLumaUnit(_ v: Float) -> UInt32 {
            let scaled = Double(v) / 0.0001
            return UInt32(max(0, min(scaled.rounded(), Double(UInt32.max))))
        }

        // Order is G, B, R per spec.
        appendU16BE(toUnit(xy.gx))
        appendU16BE(toUnit(xy.bx))
        appendU16BE(toUnit(xy.rx))
        appendU16BE(toUnit(xy.gy))
        appendU16BE(toUnit(xy.by))
        appendU16BE(toUnit(xy.ry))
        appendU16BE(toUnit(xy.wx))
        appendU16BE(toUnit(xy.wy))
        appendU32BE(toLumaUnit(maxLuma))
        appendU32BE(toLumaUnit(minLuma))

        return bytes.withUnsafeBufferPointer { buf in
            CFDataCreate(kCFAllocatorDefault, buf.baseAddress, buf.count)
        }
    }

    // H.265 content_light_level_info SEI payload, big-endian, 4 bytes:
    //   max_content_light_level     uint16 (cd/m^2)
    //   max_pic_average_light_level uint16 (cd/m^2)
    private static func makeContentLightLevelCVData(maxCLL: Float,
                                                    maxFALL: Float) -> CFData
    {
        func clamp16(_ v: Float) -> UInt16 {
            let r = v.rounded()
            if r <= 0 { return 0 }
            if r >= Float(UInt16.max) { return UInt16.max }
            return UInt16(r)
        }
        let cll  = clamp16(maxCLL)
        let fall = clamp16(maxFALL)
        let bytes: [UInt8] = [
            UInt8(cll  >> 8), UInt8(cll  & 0xFF),
            UInt8(fall >> 8), UInt8(fall & 0xFF),
        ]
        return bytes.withUnsafeBufferPointer { buf in
            CFDataCreate(kCFAllocatorDefault, buf.baseAddress, buf.count)!
        }
    }
}

// VK_FORMAT_B8G8R8A8_UNORM = 44 (we hardcode rather than depend on
// vulkan_core.h being visible to Swift).
private let VK_FORMAT_B8G8R8A8_UNORM_VALUE: Int32 = 44

#endif
