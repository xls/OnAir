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
    private static let split: Float = 0   // the line between trace and waterfall, in clip space: half each

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let waterfallPipeline, tracePipeline: MTLRenderPipelineState
    private let texture: MTLTexture
    // hot data, touched for every pixel: kept out of SwiftUI's change tracking
    @ObservationIgnored private var bins = [Float](repeating: -120, count: SpectrumRenderer.binCount)
    @ObservationIgnored private var meta = [Double](repeating: 0, count: 6)
    @ObservationIgnored private var rowPixels = [UInt32](repeating: 0, count: SpectrumRenderer.binCount)
    @ObservationIgnored private var colours = [UInt32](repeating: 0, count: 256)
    @ObservationIgnored private var row = 0
    @ObservationIgnored private var noiseFloor: Float = -1000

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

    /// The dB shown from the bottom of the plot to the top: less makes the signals taller.
    private(set) var dbRange: Float = {
        if let i = CommandLine.arguments.firstIndex(of: "--spec-range"), i + 1 < CommandLine.arguments.count, let value = Float(CommandLine.arguments[i + 1]) { return value }
        let saved = UserDefaults.standard.float(forKey: "spectrumRange")
        return saved > 0 ? saved : 80
    }()

    private var peakHold: Float = -500   // the strongest signal lately, falling slowly

    /// The least range that keeps the strongest signal inside the plot: as tall as it goes without clipping.
    private var fittingRange: Float { max(peakHold - (noiseFloor - Self.belowFloor) + 2, 10) }

    func scaleHeight(by factor: Float, done: Bool) {
        dbRange = min(max(dbRange * factor, fittingRange), Self.flatRange)
        if done { UserDefaults.standard.set(dbRange, forKey: "spectrumRange") }
    }

    private static let belowFloor: Float = 15
    private static let flatRange: Float = 1500    // the shortest setting: the trace is close to a flat line

    func refreshColours() { onair_colormap(&colours, Int32(colours.count)) }

    private func takeLine() {
        var got = false
        while onair_spectrum(&bins, Int32(Self.binCount), &meta) { got = true }
        guard got else { return }
        if centreHz != meta[0] { centreHz = meta[0] }
        if spanHz != meta[1] { spanHz = meta[1] }
        // the desktop's range tracking runs in its drawing code, so the floor is measured here: the 20th percentile of the line, smoothed
        let sample = stride(from: 0, to: Self.binCount, by: 16).map { bins[$0] }.sorted()
        let floorNow = sample[sample.count / 5]
        noiseFloor = noiseFloor < -500 ? floorNow : noiseFloor + (floorNow - noiseFloor) * 0.05
        peakHold = max(bins.max() ?? peakHold, peakHold - 0.05)
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
        if UIFreeze.shared.on { return }   // the last frame stays on the screen
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
        let low = noiseFloor - Self.belowFloor, range = max(dbRange, fittingRange)
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

struct SpectrumMetalView: UIViewRepresentable {
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

/// Reads the finger gestures. UIKit is used here because it can tell one finger from two. Two fingers either pan or zoom, whichever their
/// first movement shows; after that the gesture stays that kind until the fingers lift. Up and down changes the height of the signals.
private struct SpectrumGestures: UIViewRepresentable {
    enum TwoFingers { case undecided, pan, zoom, height }

    let tap: (CGFloat) -> Void
    let scrub: (CGFloat, Bool) -> Void              // one finger: points from the start, finished
    let pan: (CGFloat, Bool) -> Void                // two fingers: change in points since the last call, finished
    let zoom: (Double, Bool) -> Void                // scale from the start, finished
    let height: (Float, Bool) -> Void               // two fingers up or down: scale of the dB range since the last call, finished

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isMultipleTouchEnabled = true
        let c = context.coordinator
        let tapper = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tapped(_:)))
        let onePan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.panned(_:)))
        onePan.maximumNumberOfTouches = 1
        let twoPan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.twoPanned(_:)))
        twoPan.minimumNumberOfTouches = 2
        twoPan.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinched(_:)))
        twoPan.delegate = c
        pinch.delegate = c
        [tapper, onePan, twoPan, pinch].forEach(view.addGestureRecognizer)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { context.coordinator.parent = self }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: SpectrumGestures?
        private var lastPan: CGFloat = 0
        private var lastHeight: CGFloat = 0
        private var mode = TwoFingers.undecided
        private var scale = 1.0

        func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool { true }

        @objc func tapped(_ r: UITapGestureRecognizer) { parent?.tap(r.location(in: r.view).x) }

        @objc func panned(_ r: UIPanGestureRecognizer) {
            parent?.scrub(r.translation(in: r.view).x, r.state == .ended || r.state == .cancelled)
        }

        @objc func twoPanned(_ r: UIPanGestureRecognizer) {
            let x = r.translation(in: r.view).x, y = r.translation(in: r.view).y
            let done = r.state == .ended || r.state == .cancelled
            if mode == .undecided, abs(x) > 14 || abs(y) > 14 {
                mode = abs(y) > abs(x) ? .height : .pan
                lastPan = x   // the view starts moving here, without a jump
                lastHeight = y
            }
            if mode == .pan { parent?.pan(x - lastPan, done) }
            if mode == .height { parent?.height(Float(exp(Double(y - lastHeight) / 110)), done) }   // up: taller signals
            lastPan = x
            lastHeight = y
            if done { finish() }
        }

        @objc func pinched(_ r: UIPinchGestureRecognizer) {
            scale = r.scale
            let done = r.state == .ended || r.state == .cancelled
            if mode == .undecided, abs(scale - 1) > 0.1 { mode = .zoom }
            if mode == .zoom { parent?.zoom(scale, done) }
            if done { finish() }
        }

        private func finish() {
            mode = .undecided
            lastPan = 0
            lastHeight = 0
            scale = 1
        }
    }
}

/// One finger scrubs the tuning, two fingers pan, a pinch zooms, a tap jumps to a frequency.
struct SpectrumPage: View {
    let receiver: Receiver
    let spectrum: SpectrumRenderer
    @State private var pinchStart: Double?
    @State private var scrubStart: Double?
    @State private var lastScrub = 0.0
    @State private var lastTuneTime = Date.distantPast
    @State private var panRemainderMhz = 0.0
    @State private var haptics = DetentHaptics()

    var body: some View {
        // three equal parts: the trace and the waterfall share the top two thirds, the scopes have the rest and take no tuning gestures
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // a bezel around the screen, as on a bench analyser
                ZStack {
                    BrushedMetal(tone: 0.46)
                    GlassWindow(corner: 8) {
                        GeometryReader { screen in
                            spectrumArea(width: screen.size.width)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .frame(height: geometry.size.height * 2 / 3)
                ScopePanel(isFM: receiver.status.family == OnAirFamily.fm, running: receiver.status.running)
                    .frame(height: geometry.size.height / 3)
            }
        }
    }

    private func spectrumArea(width: CGFloat) -> some View {
            ZStack(alignment: .topLeading) {
                SpectrumMetalView(renderer: spectrum)
                FilterBox(receiver: receiver, spectrum: spectrum)
                marker(width: width)
                axis
                if !receiver.status.running {
                    Text("Press play to start").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
                SpectrumGestures(
                    tap: { x in
                        onair_spectrum_tune(spectrum.frequency(atFraction: x / width) / 1e6)
                        receiver.refresh()
                    },
                    scrub: { points, done in scrub(points: points, width: width, done: done) },
                    pan: { change, done in pan(change: change, width: width, done: done) },
                    zoom: { scale, done in zoom(scale: scale, done: done) },
                    height: { factor, done in spectrum.scaleHeight(by: factor, done: done) }
                )
                if spectrum.visibleSpan < 1 {
                    HardwareKey(lit: true, action: resetZoom) {
                        EngravedLabel(text: "RESET", size: 8)
                    }
                    .frame(width: 66, height: 46)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
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
            if receiver.status.running {
                Text(String(format: "%.3f", spectrum.lowHz / 1e6))
                Spacer()
                Text(Receiver.frequencyText(mhz: spectrum.frequency(atFraction: 0.5) / 1e6))
                Spacer()
                Text(String(format: "%.3f", spectrum.highHz / 1e6))
            } else {  // no capture, so no span: only where it is tuned
                Spacer()
                Text(Receiver.frequencyText(mhz: receiver.status.mhz))
                Spacer()
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(6)
        .allowsHitTesting(false)
    }

    private var step: Double { receiver.status.family == OnAirFamily.fm ? 0.1 : 0.0125 }

    /// The view moves first. What it cannot move, because it has reached the edge of the capture, retunes the radio, so a pan crosses the band.
    private func pan(change: CGFloat, width: CGFloat, done: Bool) {
        let wanted = spectrum.visibleCentre - change / width * spectrum.visibleSpan
        let left = spectrum.visibleSpan / 2, right = 1 - left
        let clamped = min(max(wanted, left), right)
        spectrum.visibleCentre = clamped
        panRemainderMhz += (wanted - clamped) * spectrum.spanHz / 1e6
        guard abs(panRemainderMhz) >= step, done || Date().timeIntervalSince(lastTuneTime) > 0.08 else {
            if done { panRemainderMhz = 0 }
            return
        }
        let steps = (panRemainderMhz / step).rounded(.towardZero)
        panRemainderMhz = done ? 0 : panRemainderMhz - steps * step
        lastTuneTime = Date()
        haptics.tick()
        receiver.tune(mhz: receiver.status.mhz + steps * step)
    }

    private func scrub(points: CGFloat, width: CGFloat, done: Bool) {
        let start = scrubStart ?? receiver.status.mhz
        scrubStart = done ? nil : start
        let spanMhz = (spectrum.highHz - spectrum.lowHz) / 1e6
        let fine = scrubStep(spanMhz: spanMhz, width: width)
        let snapped = ((start + points / width * spanMhz) / fine).rounded() * fine
        guard abs(snapped - lastScrub) >= fine / 2, done || Date().timeIntervalSince(lastTuneTime) > 0.04 else { return }
        lastScrub = done ? 0 : snapped
        lastTuneTime = Date()
        haptics.tick()
        onair_spectrum_scrub(snapped)
        receiver.refresh()
        keepInView(mhz: snapped)
    }

    private func scrubStep(spanMhz: Double, width: CGFloat) -> Double {
        // one point of finger travel is one point of the view, so the step follows the zoom
        let perPoint = spanMhz / max(width, 1)
        return [0.001, 0.005, 0.0125, 0.025, 0.1, 0.5].first { $0 >= perPoint } ?? 1
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

    private func resetZoom() {
        spectrum.visibleSpan = 1
        spectrum.visibleCentre = 0.5
    }

    private func zoom(scale: Double, done: Bool) {
        let start = pinchStart ?? spectrum.visibleSpan
        pinchStart = done ? nil : start
        setView(centre: spectrum.visibleCentre, span: start / max(scale, 0.01))
    }

    private func setView(centre: Double, span: Double) {
        let span = min(max(span, 0.02), 1)
        spectrum.visibleSpan = span
        spectrum.visibleCentre = min(max(centre, span / 2), 1 - span / 2)
    }
}

/// The band the receiver is listening to, as a yellow box on the spectrum, so a signal can be matched to the filter by eye.
struct FilterBox: View {
    let receiver: Receiver
    let spectrum: SpectrumRenderer

    var body: some View {
        GeometryReader { geometry in
            let span = spectrum.highHz - spectrum.lowHz
            if receiver.status.running, span > 0, let band = receiver.filterBand {
                let left = geometry.size.width * (band.lowerBound - spectrum.lowHz) / span
                let right = geometry.size.width * (band.upperBound - spectrum.lowHz) / span
                let width = max(right - left, 2)   // always visible, however narrow against the span
                Rectangle()
                    .fill(Color.yellow.opacity(0.22))
                    .overlay(Rectangle().stroke(Color.yellow.opacity(0.75), lineWidth: 1))
                    .frame(width: width, height: geometry.size.height)
                    .offset(x: left)
            }
        }
        .allowsHitTesting(false)
    }
}
