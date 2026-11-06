import MetalKit
import OnAirCore
import SwiftUI

private let shaders = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms { float u0, u1, row, split; };
struct Out { float4 position [[position]]; float2 uv; float alpha; };

vertex Out waterfallVertex(uint id [[vertex_id]], constant Uniforms& u [[buffer(0)]]) {
    const float2 corner[4] = {float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1)};
    float2 c = corner[id];
    Out o;
    o.position = float4(c.x * 2 - 1, u.split - c.y * (u.split + 1), 0, 1);
    o.uv = c;
    o.alpha = 1;
    return o;
}

fragment float4 waterfallFragment(Out in [[stage_in]], constant Uniforms& u [[buffer(0)]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(address::repeat, filter::linear);
    return tex.sample(s, float2(u.u0 + in.uv.x * (u.u1 - u.u0), u.row + in.uv.y));
}

vertex Out traceVertex(uint id [[vertex_id]], constant float3* points [[buffer(1)]]) {
    Out o;
    o.position = float4(points[id].xy, 0, 1);
    o.uv = 0;
    o.alpha = points[id].z;
    return o;
}

fragment float4 traceFragment(Out in [[stage_in]]) {
    return float4(0.45, 0.72, 0.82, 1) * in.alpha;
}
"""

/// Draws the spectrum trace and the waterfall with Metal. It outlives the page, so the waterfall's history stays.
@Observable
final class SpectrumRenderer: NSObject, MTKViewDelegate {
    private struct Uniforms { var u0: Float, u1: Float, row: Float, split: Float }

    private static let binCount = 2048
    private static let historyRows = 512
    private static let split: Float = 0.15   // the line between trace and waterfall, in clip space

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let waterfallPipeline, tracePipeline: MTLRenderPipelineState
    private let texture: MTLTexture
    private var bins = [Float](repeating: -120, count: SpectrumRenderer.binCount)
    private var meta = [Double](repeating: 0, count: 6)
    private var rowPixels = [UInt32](repeating: 0, count: SpectrumRenderer.binCount)
    private var colours = [UInt32](repeating: 0, count: 256)
    private var row = 0
    private var noiseFloor: Float = -1000

    /// The visible part of the capture, 0...1.
    var visibleCentre = 0.5
    var visibleSpan = 1.0
    private(set) var centreHz = 0.0
    private(set) var spanHz = 0.0

    var lowHz: Double { centreHz + (visibleCentre - visibleSpan / 2 - 0.5) * spanHz }
    var highHz: Double { lowHz + visibleSpan * spanHz }

    func frequency(atFraction x: Double) -> Double { lowHz + x * (highHz - lowHz) }

    override init() {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        let library = try! device.makeLibrary(source: shaders, options: nil)
        let pipeline = { [device] (vertex: String, fragment: String) -> MTLRenderPipelineState in
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            d.colorAttachments[0].isBlendingEnabled = true
            d.colorAttachments[0].sourceRGBBlendFactor = .one
            d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            return try! device.makeRenderPipelineState(descriptor: d)
        }
        waterfallPipeline = pipeline("waterfallVertex", "waterfallFragment")
        tracePipeline = pipeline("traceVertex", "traceFragment")
        let t = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: Self.binCount, height: Self.historyRows, mipmapped: false)
        texture = device.makeTexture(descriptor: t)!
        super.init()
    }

    func refreshColours() { onair_colormap(&colours, Int32(colours.count)) }

    private func takeLine() {
        var got = false
        while onair_spectrum(&bins, Int32(Self.binCount), &meta) { got = true }
        guard got else { return }
        centreHz = meta[0]
        spanHz = meta[1]
        // the desktop's range tracking runs in its drawing code, so the floor is measured here: the 20th percentile of the line, smoothed
        let floorNow = bins.sorted()[Self.binCount / 5]
        noiseFloor = noiseFloor < -500 ? floorNow : noiseFloor + (floorNow - noiseFloor) * 0.05
        let low = noiseFloor - 3, range: Float = 45
        for i in 0..<Self.binCount {
            let level = min(max((bins[i] - low) / range, 0), 1)
            rowPixels[i] = colours[Int(level * 255)]
        }
        row = (row + Self.historyRows - 1) % Self.historyRows
        texture.replace(region: MTLRegionMake2D(0, row, Self.binCount, 1), mipmapLevel: 0, withBytes: rowPixels, bytesPerRow: Self.binCount * 4)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard onair_is_started() else { return }
        takeLine()
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(), let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        let u0 = Float(visibleCentre - visibleSpan / 2), u1 = Float(visibleCentre + visibleSpan / 2)
        var uniforms = Uniforms(u0: u0, u1: u1, row: Float(row) / Float(Self.historyRows), split: Self.split)
        encoder.setRenderPipelineState(waterfallPipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        let columns = max(min(Int(view.drawableSize.width / 2), 800), 2)
        let top: Float = 1, bottom = Self.split
        let low = noiseFloor - 15, range: Float = 80
        var fill = [SIMD3<Float>](), line = [SIMD3<Float>]()
        fill.reserveCapacity(columns * 2)
        line.reserveCapacity(columns)
        for c in 0..<columns {
            let f = Float(c) / Float(columns - 1)
            let start = Int((u0 + f * (u1 - u0)) * Float(Self.binCount - 1))
            let end = Int((u0 + (f + 1 / Float(columns)) * (u1 - u0)) * Float(Self.binCount - 1))
            var peak = bins[min(max(start, 0), Self.binCount - 1)]
            if end > start { for k in start...min(end, Self.binCount - 1) where k >= 0 { peak = max(peak, bins[k]) } }
            let level = min(max((peak - low) / range, 0), 1)
            let x = f * 2 - 1, y = bottom + level * (top - bottom)
            fill.append(SIMD3(x, y, 0.28))
            fill.append(SIMD3(x, bottom, 0.02))
            line.append(SIMD3(x, y, 1))
        }
        encoder.setRenderPipelineState(tracePipeline)
        fill.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: fill.count)
        line.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
        encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: line.count)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}

private struct SpectrumMetalView: UIViewRepresentable {
    let renderer: SpectrumRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.delegate = renderer
        renderer.refreshColours()
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}
}

/// Tap to tune, drag to scrub the tuning, pinch to zoom.
struct SpectrumPage: View {
    let receiver: Receiver
    let spectrum: SpectrumRenderer
    @State private var pinchStart: Double?
    @State private var dragStart: Double?
    @State private var lastScrub = 0.0
    @State private var lastScrubTime = Date.distantPast
    @State private var haptics = DetentHaptics()

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                SpectrumMetalView(renderer: spectrum)
                marker(width: geometry.size.width)
                axis
                if !receiver.status.running {
                    Text("Press play to start").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(tap(width: geometry.size.width))
            .simultaneousGesture(drag(width: geometry.size.width))
            .simultaneousGesture(pinch)
        }
    }

    private func marker(width: CGFloat) -> some View {
        let span = spectrum.highHz - spectrum.lowHz
        let x = span > 0 ? (receiver.status.mhz * 1e6 - spectrum.lowHz) / span : 0.5
        return Rectangle()
            .fill(Color.orange.opacity(0.8))
            .frame(width: 1)
            .offset(x: width * x)
            .allowsHitTesting(false)
    }

    private var axis: some View {
        HStack {
            Text(String(format: "%.3f", spectrum.lowHz / 1e6))
            Spacer()
            Text(String(format: "%.3f MHz", spectrum.frequency(atFraction: 0.5) / 1e6))
            Spacer()
            Text(String(format: "%.3f", spectrum.highHz / 1e6))
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(6)
        .allowsHitTesting(false)
    }

    private func tap(width: CGFloat) -> some Gesture {
        SpatialTapGesture().onEnded { value in
            onair_spectrum_tune(spectrum.frequency(atFraction: value.location.x / width) / 1e6)
            receiver.refresh()
        }
    }

    /// One finger scrubs the tuning: the marker follows the finger, and the receiver retunes as it moves.
    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4).onChanged { value in
            let start = dragStart ?? receiver.status.mhz
            dragStart = start
            let spanMhz = (spectrum.highHz - spectrum.lowHz) / 1e6
            let step = scrubStep(spanMhz: spanMhz, width: width)
            let wanted = start + value.translation.width / width * spanMhz
            let snapped = (wanted / step).rounded() * step
            guard abs(snapped - lastScrub) >= step / 2, Date().timeIntervalSince(lastScrubTime) > 0.04 else { return }
            lastScrub = snapped
            lastScrubTime = Date()
            haptics.tick()
            onair_spectrum_tune(snapped)
            receiver.refresh()
            keepInView(mhz: snapped)
        }
        .onEnded { _ in
            dragStart = nil
            lastScrub = 0
        }
    }

    private func scrubStep(spanMhz: Double, width: CGFloat) -> Double {
        if receiver.status.family == OnAirFamily.fm { return 0.1 }
        let perPoint = spanMhz / max(width, 1)
        return [0.0001, 0.001, 0.005, 0.0125, 0.025, 0.1, 0.5].first { $0 >= perPoint } ?? 1
    }

    /// While zoomed in, the view moves along with the marker when it nears an edge.
    private func keepInView(mhz: Double) {
        guard spectrum.visibleSpan < 1, spectrum.spanHz > 0 else { return }
        let fraction = (mhz * 1e6 - spectrum.centreHz) / spectrum.spanHz + 0.5
        let margin = spectrum.visibleSpan * 0.15
        let low = spectrum.visibleCentre - spectrum.visibleSpan / 2 + margin
        let high = spectrum.visibleCentre + spectrum.visibleSpan / 2 - margin
        if fraction < low { setView(centre: spectrum.visibleCentre - (low - fraction), span: spectrum.visibleSpan) }
        if fraction > high { setView(centre: spectrum.visibleCentre + (fraction - high), span: spectrum.visibleSpan) }
    }

    private var pinch: some Gesture {
        MagnifyGesture().onChanged { value in
            let start = pinchStart ?? spectrum.visibleSpan
            pinchStart = start
            setView(centre: spectrum.visibleCentre, span: start / value.magnification)
        }
        .onEnded { _ in pinchStart = nil }
    }

    private func setView(centre: Double, span: Double) {
        let span = min(max(span, 0.02), 1)
        spectrum.visibleSpan = span
        spectrum.visibleCentre = min(max(centre, span / 2), 1 - span / 2)
    }
}
