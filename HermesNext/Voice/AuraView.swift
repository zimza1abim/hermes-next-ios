import MetalKit
import SwiftUI
import HermesVoiceCore

/// Full-screen aura. The display link lives in MTKView, so a frame does not rebuild the SwiftUI tree.
struct AuraLayer: View {
    var animator: AuraAnimator
    var calm: Bool
    var detail: Float
    var halfRate: Bool
    var mini: Bool
    var palette: AuraPalette
    var heightMap: (Float) -> Float = { $0 }
    var signals: () -> (mic: Float, playback: Float, revealed: Int)
    var onRevealed: (Int) -> Void = { _ in }

    @State private var metalFailed = false

    var body: some View {
        Group {
            if metalFailed {
                FallbackAura(animator: animator, calm: calm, detail: detail, halfRate: halfRate, mini: mini, palette: palette, heightMap: heightMap, signals: signals, onRevealed: onRevealed)
            } else {
                AuraMetalView(animator: animator, calm: calm, detail: detail, halfRate: halfRate, mini: mini, palette: palette, heightMap: heightMap, signals: signals, onRevealed: onRevealed, onFailure: { metalFailed = true })
            }
        }
        .allowsHitTesting(false)
    }
}

struct AuraMetalView: UIViewRepresentable {
    var animator: AuraAnimator
    var calm: Bool
    var detail: Float
    var halfRate: Bool
    var mini: Bool
    var palette: AuraPalette
    var heightMap: (Float) -> Float
    var signals: () -> (mic: Float, playback: Float, revealed: Int)
    var onRevealed: (Int) -> Void
    var onFailure: () -> Void

    func makeCoordinator() -> Renderer { Renderer() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        guard let device = MTLCreateSystemDefaultDevice() else {
            DispatchQueue.main.async { onFailure() }
            return view
        }
        view.device = device
        view.framebufferOnly = true
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = halfRate ? 30 : 60
        view.colorPixelFormat = .bgra8Unorm
        view.isOpaque = true
        view.clearColor = MTLClearColor(red: 0.043, green: 0.043, blue: 0.063, alpha: 1)
        view.delegate = context.coordinator
        if !context.coordinator.prepare(device: device) {
            DispatchQueue.main.async { onFailure() }
        }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        view.preferredFramesPerSecond = halfRate ? 30 : 60
        context.coordinator.animator = animator
        context.coordinator.calm = calm
        context.coordinator.detail = detail
        context.coordinator.halfRate = halfRate
        context.coordinator.mini = mini
        context.coordinator.palette = palette
        context.coordinator.heightMap = heightMap
        context.coordinator.signals = signals
        context.coordinator.onRevealed = onRevealed
    }
}

final class Renderer: NSObject, MTKViewDelegate {
    var animator = AuraAnimator()
    var calm = false
    var detail: Float = 4
    var halfRate = false
    var mini = false
    var palette = AuraPalette.nova
    var heightMap: (Float) -> Float = { $0 }
    var signals: () -> (mic: Float, playback: Float, revealed: Int) = { (0, 0, 0) }
    var onRevealed: (Int) -> Void = { _ in }

    private var pipeline: MTLRenderPipelineState?
    private var queue: MTLCommandQueue?
    private let engine = CallFrameEngine()
    private var last = CACurrentMediaTime()
    private var reported = -1

    func prepare(device: MTLDevice) -> Bool {
        queue = device.makeCommandQueue()
        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "aura_vertex"),
              let fragment = library.makeFunction(name: "aura_fragment") else { return false }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        return pipeline != nil && queue != nil
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dtMs = Float(min(max((now - last) * 1000, 0), 100))
        last = now
        let sample = signals()
        let drawThis = engine.step(
            dtMs: dtMs == 0 ? 16 : dtMs,
            micRMS: sample.mic,
            playbackRMS: sample.playback,
            revealed: sample.revealed,
            animator: animator,
            calm: calm,
            detail: detail,
            skipEveryOther: halfRate,
            heightMap: heightMap
        )
        if engine.revealedChars != reported {
            reported = engine.revealedChars
            let value = reported
            let callback = onRevealed
            DispatchQueue.main.async { callback(value) }
        }
        guard drawThis, let pipeline, let queue, let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var bytes = AuraGPU.encode(engine.uniforms, view: view, mini: mini, palette: palette)
        encoder.setRenderPipelineState(pipeline)
        bytes.withUnsafeBytes { raw in
            encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

enum AuraGPU {
    static func encode(_ u: AuraUniformValues, view: MTKView, mini: Bool, palette: AuraPalette) -> Data {
        let scale = view.window?.screen.scale ?? view.contentScaleFactor
        let screen = view.window?.bounds.size ?? view.bounds.size
        let origin = view.convert(CGPoint.zero, to: view.window)
        var data = Data(count: 128)
        func put(_ value: Float, _ offset: Int) {
            var v = value
            withUnsafeBytes(of: &v) { raw in
                data.replaceSubrange(offset..<(offset + 4), with: raw)
            }
        }
        func put2(_ x: Float, _ y: Float, _ offset: Int) { put(x, offset); put(y, offset + 4) }
        func put4(_ c: RGB, _ offset: Int) { put(c.r, offset); put(c.g, offset + 4); put(c.b, offset + 8); put(1, offset + 12) }
        put2(Float(screen.width * scale), Float(screen.height * scale), 0)
        put2(Float(origin.x * scale), Float(origin.y * scale), 8)
        put(u.time, 16)
        put(u.flow, 20)
        put(u.height, 24)
        put(u.swell, 28)
        put(u.ripple, 32)
        put(u.sweep, 36)
        put(u.flash, 40)
        put(u.dir, 44)
        put(u.brightness, 48)
        put(u.saturation, 52)
        put(mini ? 1 : 0, 56)
        put(u.detail, 60)
        put4(palette.a, 64)
        put4(palette.b, 80)
        put4(palette.c, 96)
        put4(palette.d, 112)
        return data
    }
}

/// Gradient stand-in used when Metal can't build the shader (and for the reduced-motion colour wash
/// only if the shader itself failed). It reads the same uniforms, so the mood still changes.
struct FallbackAura: View {
    var animator: AuraAnimator
    var calm: Bool
    var detail: Float
    var halfRate: Bool
    var mini: Bool
    var palette: AuraPalette
    var heightMap: (Float) -> Float
    var signals: () -> (mic: Float, playback: Float, revealed: Int)
    var onRevealed: (Int) -> Void
    @State private var engine = CallFrameEngine()

    var body: some View {
        let interval = halfRate ? 1.0 / 30 : 1.0 / 60
        TimelineView(.animation(minimumInterval: interval, paused: false)) { _ in
            Canvas { context, size in
                paint(&context, size: size)
            }
            .onChange(of: engine.revealedChars) { _, value in onRevealed(value) }
        }
    }

    private func paint(_ context: inout GraphicsContext, size: CGSize) {
        let sample = signals()
        let dt = Float(halfRate ? 33 : 16)
        _ = engine.step(dtMs: dt, micRMS: sample.mic, playbackRMS: sample.playback, revealed: sample.revealed, animator: animator, calm: calm, detail: detail, skipEveryOther: false, heightMap: heightMap)
        let uniforms = engine.uniforms
        let edge = size.height * CGFloat(1 - uniforms.height - 0.10 * uniforms.swell)
        let ground = Gradient(colors: [CallTokens.base, CallTokens.baseDeep])
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(ground, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        let bright = Double(uniforms.brightness)
        let wash = Gradient(colors: [
            Color.clear,
            Color(rgb: palette.b).opacity(0.55 * bright),
            Color(rgb: palette.a).opacity(0.75 * bright),
        ])
        let band = CGRect(x: 0, y: edge, width: size.width, height: size.height - edge)
        context.fill(Path(band), with: .linearGradient(wash, startPoint: CGPoint(x: 0, y: edge), endPoint: CGPoint(x: 0, y: size.height)))
        let crestAmount = (0.35 + 0.25 * Double(uniforms.swell) + 0.5 * Double(uniforms.flash)) * bright
        let crest = Color(rgb: palette.c).opacity(crestAmount)
        context.fill(Path(CGRect(x: 0, y: edge - 8, width: size.width, height: 16)), with: .color(crest))
    }
}

extension Color {
    init(rgb: RGB) {
        self.init(red: Double(rgb.r), green: Double(rgb.g), blue: Double(rgb.b))
    }
}
