import SwiftUI
import GameController
import MetalKit
import CoreVideo

struct MetalVideoView: UIViewControllerRepresentable {
    let mailbox: VideoFrameMailbox
    let statistics: (Int, Double) -> Void
    let presented: (Result<Void, Error>) -> Void
    func makeCoordinator() -> Renderer { Renderer(mailbox: mailbox, presented: presented, statistics: statistics) }
    func makeUIViewController(context: Context) -> StreamVideoController {
        let controller = StreamVideoController()
        controller.controllerUserInteractionEnabled = false
        let view = StreamMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.isPaused = false; view.enableSetNeedsDisplay = false; view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        do { try context.coordinator.configure(view) }
        catch { DispatchQueue.main.async { presented(.failure(error)) } }
        controller.view = view
        return controller
    }
    func updateUIViewController(_ controller: StreamVideoController, context: Context) {
        // Renderer polls the newest decoded frame at the display's cadence.
    }
    final class Renderer: NSObject, MTKViewDelegate {
        private let mailbox: VideoFrameMailbox
        private let statistics: (Int, Double) -> Void
        private var lastSerial = 0
        private var displayed = 0
        private var statisticsTime = ProcessInfo.processInfo.systemUptime
        private var cache: CVMetalTextureCache?
        private var pipeline: MTLRenderPipelineState?
        private var pyroPipeline: MTLRenderPipelineState?
        private var queue: MTLCommandQueue?
        private var reported = false
        private var capturedDiagnosticFrame = false
        private let presented: (Result<Void, Error>) -> Void
        init(mailbox: VideoFrameMailbox, presented: @escaping (Result<Void, Error>) -> Void, statistics: @escaping (Int, Double) -> Void) {
            self.mailbox = mailbox; self.presented = presented; self.statistics = statistics
        }
        enum RenderError: Error { case unavailable, invalidPixelBuffer, texture, gpu }
        func configure(_ view: MTKView) throws {
            guard let device = view.device, let queue = device.makeCommandQueue() else { throw RenderError.unavailable }
            self.queue = queue
            guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess else { throw RenderError.texture }
            let source = """
            #include <metal_stdlib>
            using namespace metal;
            struct Vertex { float4 position [[position]]; float2 uv; };
            vertex Vertex videoVertex(uint id [[vertex_id]], constant float2 &scale [[buffer(0)]]) {
                const float2 p[4] = {float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,1)};
                const float2 uv[4] = {float2(0,1),float2(1,1),float2(0,0),float2(1,0)};
                return {float4(p[id]*scale,0,1),uv[id]};
            }
            fragment float4 videoFragment(Vertex in [[stage_in]], texture2d<float> y [[texture(0)]], texture2d<float> uv [[texture(1)]]) {
                constexpr sampler s(filter::linear,address::clamp_to_edge);
                float l = (y.sample(s,in.uv).r - 16.0/255.0)*(255.0/219.0);
                float2 c = (uv.sample(s,in.uv).rg - 128.0/255.0)*(255.0/224.0);
                return float4(l + 1.5748*c.y, l - 0.187324*c.x - 0.468124*c.y, l + 1.8556*c.x, 1);
            }
            fragment float4 pyroFragment(Vertex in [[stage_in]], texture2d<float> y [[texture(0)]], texture2d<float> cb [[texture(1)]], texture2d<float> cr [[texture(2)]]) {
                constexpr sampler s(filter::linear,address::clamp_to_edge);
                float l = (y.sample(s,in.uv).r - 16.0/255.0)*(255.0/219.0);
                float u = (cb.sample(s,in.uv).r - 128.0/255.0)*(255.0/224.0);
                float v = (cr.sample(s,in.uv).r - 128.0/255.0)*(255.0/224.0);
                return float4(l + 1.5748*v, l - 0.187324*u - 0.468124*v, l + 1.8556*u, 1);
            }
            """
            let library = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "videoVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "videoFragment")
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            descriptor.fragmentFunction = library.makeFunction(name: "pyroFragment")
            pyroPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) {
            if let frame = mailbox.takePyroFrame() {
                drawPyro(frame, in: view)
                return
            }
            guard let (image, serial) = mailbox.latest(), serial != lastSerial, let cache, let pipeline, let command = queue?.makeCommandBuffer(),
                  let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return }
            guard CVPixelBufferGetPlaneCount(image) == 2,
                  CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
                report(.failure(RenderError.invalidPixelBuffer)); return
            }
            var luma: CVMetalTexture?, chroma: CVMetalTexture?
            let y = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, image, nil, .r8Unorm,
                CVPixelBufferGetWidthOfPlane(image, 0), CVPixelBufferGetHeightOfPlane(image, 0), 0, &luma)
            let uv = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, image, nil, .rg8Unorm,
                CVPixelBufferGetWidthOfPlane(image, 1), CVPixelBufferGetHeightOfPlane(image, 1), 1, &chroma)
            guard y == kCVReturnSuccess, uv == kCVReturnSuccess, let luma, let chroma,
                  let yt = CVMetalTextureGetTexture(luma), let uvt = CVMetalTextureGetTexture(chroma),
                  let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { report(.failure(RenderError.texture)); return }
            let videoAspect = Float(CVPixelBufferGetWidth(image)) / Float(CVPixelBufferGetHeight(image))
            let screenAspect = Float(drawable.texture.width) / Float(max(1, drawable.texture.height))
            var scale = SIMD2<Float>(min(1, videoAspect / screenAspect), min(1, screenAspect / videoAspect))
            encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                width: Double(drawable.texture.width), height: Double(drawable.texture.height), znear: 0, zfar: 1))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            encoder.setFragmentTexture(yt, index: 0); encoder.setFragmentTexture(uvt, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            command.present(drawable)
            command.addCompletedHandler { [weak self, image, luma, chroma] completed in
                withExtendedLifetime((image, luma, chroma)) {}
                DispatchQueue.main.async { self?.report(completed.status == .completed ? .success(()) : .failure(RenderError.gpu)) }
            }
            command.commit()
            lastSerial = serial; displayed += 1
            let now = ProcessInfo.processInfo.systemUptime
            if now - statisticsTime >= 1 {
                statistics(displayed, Double(displayed) / (now - statisticsTime))
                displayed = 0; statisticsTime = now
            }
        }
        private func drawPyro(_ frame: CNPyroWaveGPUFrame, in view: MTKView) {
            // Use the decoder's queue so Vulkan decode and Metal sampling are
            // ordered without copying the image through CPU memory.
            guard let pipeline = pyroPipeline, let command = frame.commandQueue.makeCommandBuffer(),
                  let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                frame.markPresentationComplete(atTime: ProcessInfo.processInfo.systemUptime)
                return
            }
            let videoAspect = Float(frame.lumaTexture.width) / Float(frame.lumaTexture.height)
            let screenAspect = Float(drawable.texture.width) / Float(max(1, drawable.texture.height))
            var scale = SIMD2<Float>(min(1, videoAspect / screenAspect), min(1, screenAspect / videoAspect))
            encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                width: Double(drawable.texture.width), height: Double(drawable.texture.height), znear: 0, zfar: 1))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            encoder.setFragmentTexture(frame.lumaTexture, index: 0)
            encoder.setFragmentTexture(frame.cbTexture, index: 1)
            encoder.setFragmentTexture(frame.crTexture, index: 2)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            if ProcessInfo.processInfo.arguments.contains("--capture-frame"), !capturedDiagnosticFrame {
                capturedDiagnosticFrame = true
                captureLuma(frame.lumaTexture, command: command)
            }
            command.present(drawable)
            command.addCompletedHandler { [weak self, frame] completed in
                frame.markPresentationComplete(atTime: ProcessInfo.processInfo.systemUptime)
                DispatchQueue.main.async { self?.report(completed.status == .completed ? .success(()) : .failure(RenderError.gpu)) }
            }
            command.commit()
            displayed += 1
            let now = ProcessInfo.processInfo.systemUptime
            if now - statisticsTime >= 1 {
                statistics(displayed, Double(displayed) / (now - statisticsTime))
                displayed = 0; statisticsTime = now
            }
        }
        private func captureLuma(_ texture: MTLTexture, command: MTLCommandBuffer) {
            let stride = (texture.width + 255) & ~255
            guard let buffer = texture.device.makeBuffer(length: stride * texture.height, options: .storageModeShared),
                  let blit = command.makeBlitCommandEncoder() else { return }
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                to: buffer, destinationOffset: 0, destinationBytesPerRow: stride,
                destinationBytesPerImage: stride * texture.height)
            blit.endEncoding()
            command.addCompletedHandler { completed in
                guard completed.status == .completed else { return }
                let data = Data(bytes: buffer.contents(), count: buffer.length)
                guard let provider = CGDataProvider(data: data as CFData),
                      let image = CGImage(width: texture.width, height: texture.height,
                        bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: stride,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider,
                        decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                      let png = UIImage(cgImage: image).pngData(),
                      let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
                try? png.write(to: cache.appendingPathComponent("SteamTV-decoded-frame.png"))
            }
        }
        private func report(_ result: Result<Void, Error>) {
            guard !reported else { return }; reported = true; presented(result)
        }
    }
}

/// tvOS face buttons belong to the game, rather than SwiftUI Back/Exit commands.
final class StreamVideoController: GCEventViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        controllerUserInteractionEnabled = false
        view.becomeFirstResponder()
    }
}
final class StreamMetalView: MTKView {
    override var canBecomeFirstResponder: Bool { true }
}
