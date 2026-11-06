import Accelerate
import OnAirCore
import SwiftUI

enum Scope: String, CaseIterable, Identifiable {
    case audio = "AUDIO", oscilloscope = "SCOPE", goniometer = "X-Y", multiplex = "MPX", rds = "RDS"
    var id: Self { self }
    var needsFM: Bool { self == .multiplex || self == .rds }
}

/// Turns the last moment of sound into band levels, on a musical (log) frequency scale.
private final class AudioAnalyser {
    static let frames = 2048
    private let log2n = vDSP_Length(11)
    private let setup: FFTSetup
    private let window: [Float]
    private var real = [Float](repeating: 0, count: AudioAnalyser.frames / 2)
    private var imag = [Float](repeating: 0, count: AudioAnalyser.frames / 2)
    private var held: [Float] = []

    init() {
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.frames, isHalfWindow: false)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Levels 0...1. They rise at once and fall slowly, like the LEDs of a real analyser.
    func bands(_ mono: [Float], count: Int) -> [Float] {
        var windowed = vDSP.multiply(mono, window)
        var output = [Float](repeating: 0, count: Self.frames / 2)
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBufferPointer { samples in
                    samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.frames / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(Self.frames / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &output, 1, vDSP_Length(Self.frames / 2))
            }
        }
        if held.count != count { held = [Float](repeating: 0, count: count) }
        let low = 40.0, high = 18000.0, binHz = 48000.0 / Double(Self.frames)
        for band in 0..<count {
            let from = low * pow(high / low, Double(band) / Double(count))
            let to = low * pow(high / low, Double(band + 1) / Double(count))
            let first = max(Int(from / binHz), 1), last = max(Int(to / binHz), first + 1)
            let peak = output[first..<min(last, output.count)].max() ?? 0
            let db = 10 * log10(max(peak, 1e-9) / Float(Self.frames * Self.frames))
            let level = min(max((db + 72) / 66, 0), 1)
            held[band] = max(level, held[band] * 0.86)
        }
        return held
    }
}

/// Two instruments side by side under the waterfall.
struct ScopePanel: View {
    let isFM: Bool
    let running: Bool
    @AppStorage("scopeLeft") private var left = Scope.audio
    @AppStorage("scopeRight") private var right = Scope.oscilloscope

    var body: some View {
        ZStack {
            BrushedMetal(tone: 0.46)
            HStack(spacing: 8) {
                ScopeWindow(scope: $left, isFM: isFM, running: running)
                ScopeWindow(scope: $right, isFM: isFM, running: running)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }
}

/// One instrument: a window and a key that steps through what it shows.
private struct ScopeWindow: View {
    @Binding var scope: Scope
    let isFM: Bool
    let running: Bool
    @State private var analyser = AudioAnalyser()

    private var scopes: [Scope] { Scope.allCases.filter { isFM || !$0.needsFM } }

    var body: some View {
        VStack(spacing: 6) {
            GlassWindow(corner: 6) {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !running)) { timeline in
                    // reading the date inside the canvas is what makes it redraw on every tick
                    Canvas { context, size in
                        _ = timeline.date
                        draw(in: context, size: size)
                    }
                }
            }
            HardwareKey(lit: running, led: .green, action: next) {
                EngravedLabel(text: scope.rawValue, size: 8)
            }
            .frame(height: 36)
        }
        .onChange(of: isFM) { _, fm in
            if !fm && scope.needsFM { scope = .audio }
        }
    }

    private func next() {
        let index = scopes.firstIndex(of: scope) ?? 0
        scope = scopes[(index + 1) % scopes.count]
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        switch scope {
        case .audio: drawAnalyser(context, size)
        case .oscilloscope: drawOscilloscope(context, size)
        case .goniometer: drawGoniometer(context, size)
        case .multiplex: drawMultiplex(context, size)
        case .rds: drawConstellation(context, size)
        }
    }

    private func recent(_ frames: Int) -> [Float] {
        var stereo = [Float](repeating: 0, count: frames * 2)
        onair_audio_recent(&stereo, Int32(frames))
        return stereo
    }

    private func grid(_ context: GraphicsContext, _ size: CGSize, columns: Int, rows: Int) {
        var path = Path()
        for c in 1..<columns {
            let x = size.width * CGFloat(c) / CGFloat(columns)
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }
        for r in 1..<rows {
            let y = size.height * CGFloat(r) / CGFloat(rows)
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(path, with: .color(.green.opacity(0.13)), lineWidth: 0.5)
    }

    /// Stacks of LED segments: green, then amber, then red at the top.
    private func drawAnalyser(_ context: GraphicsContext, _ size: CGSize) {
        let stereo = recent(AudioAnalyser.frames)
        let mono = (0..<AudioAnalyser.frames).map { (stereo[$0 * 2] + stereo[$0 * 2 + 1]) / 2 }
        let bandCount = 20, segments = 14
        let levels = analyser.bands(mono, count: bandCount)
        let columnWidth = size.width / CGFloat(bandCount), rowHeight = size.height / CGFloat(segments)
        for band in 0..<bandCount {
            let lit = Int(levels[band] * Float(segments))
            for segment in 0..<segments {
                let colour: Color = segment >= 12 ? .red : segment >= 9 ? RadioTheme.amber : .green
                let rect = CGRect(x: CGFloat(band) * columnWidth + 1, y: size.height - CGFloat(segment + 1) * rowHeight + 1, width: columnWidth - 2, height: rowHeight - 2)
                context.fill(Path(rect), with: .color(colour.opacity(segment < lit ? 0.95 : 0.07)))
            }
        }
    }

    private func phosphor(_ context: GraphicsContext, _ path: Path) {
        context.stroke(path, with: .color(.green.opacity(0.22)), lineWidth: 5)
        context.stroke(path, with: .color(Color(red: 0.55, green: 1, blue: 0.6)), lineWidth: 1.2)
    }

    /// Starts each sweep where the wave rises through zero, so a steady tone stands still.
    private func drawOscilloscope(_ context: GraphicsContext, _ size: CGSize) {
        grid(context, size, columns: 4, rows: 4)
        let shown = 500
        let stereo = recent(shown * 2)
        let mono = (0..<shown * 2).map { (stereo[$0 * 2] + stereo[$0 * 2 + 1]) / 2 }
        var start = 0
        for i in 1..<shown where mono[i - 1] <= 0 && mono[i] > 0 {
            start = i
            break
        }
        var path = Path()
        for i in 0..<shown {
            let point = CGPoint(x: size.width * CGFloat(i) / CGFloat(shown - 1), y: size.height / 2 * (1 - CGFloat(mono[start + i]) * 1.6))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        phosphor(context, path)
    }

    /// Left against right, turned 45 degrees: mono is an upright line, wide stereo fills the circle.
    private func drawGoniometer(_ context: GraphicsContext, _ size: CGSize) {
        grid(context, size, columns: 4, rows: 4)
        let stereo = recent(700)
        let radius = size.height * 0.46, centre = CGPoint(x: size.width / 2, y: size.height / 2)
        var path = Path()
        for i in 0..<700 {
            let left = CGFloat(stereo[i * 2]), right = CGFloat(stereo[i * 2 + 1])
            let point = CGPoint(x: centre.x + (right - left) * 0.71 * radius * 1.8, y: centre.y - (left + right) * 0.71 * radius * 1.8)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        context.stroke(path, with: .color(.green.opacity(0.75)), lineWidth: 0.8)
    }

    /// The whole FM baseband, with what each part of it carries.
    private func drawMultiplex(_ context: GraphicsContext, _ size: CGSize) {
        grid(context, size, columns: 4, rows: 4)
        var db = [Float](repeating: 0, count: 2048)
        var maxHz: Float = 0
        let count = Int(onair_fm_multiplex(&db, Int32(db.count), &maxHz))
        guard count > 1, maxHz > 0 else { return }
        for (hz, name) in [(19000.0, "PILOT"), (38000.0, "L-R"), (57000.0, "RDS")] where hz < Double(maxHz) {
            let x = size.width * hz / Double(maxHz)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(RadioTheme.amber.opacity(0.45)), style: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
            context.draw(Text(name).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(RadioTheme.amber), at: CGPoint(x: x, y: 8))
        }
        let lowest = db[0..<count].min() ?? -80, highest = db[0..<count].max() ?? 0
        var path = Path()
        for i in 0..<count {
            let level = CGFloat((db[i] - lowest) / max(highest - lowest, 1))
            let point = CGPoint(x: size.width * CGFloat(i) / CGFloat(count - 1), y: size.height * (0.97 - level * 0.84))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        phosphor(context, path)
    }

    /// RDS symbols: two clean dots mean perfect decoding, a smear means noise or multipath.
    private func drawConstellation(_ context: GraphicsContext, _ size: CGSize) {
        grid(context, size, columns: 4, rows: 4)
        var xy = [Float](repeating: 0, count: 800)
        let count = Int(onair_fm_rds_symbols(&xy, 400))
        guard count > 0 else { return }
        let largest = max((0..<count * 2).map { abs(xy[$0]) }.max() ?? 1, 0.001)
        let radius = size.height * 0.42
        for i in 0..<count {
            let x = size.width / 2 + CGFloat(xy[i * 2] / largest) * radius * 1.6
            let y = size.height / 2 - CGFloat(xy[i * 2 + 1] / largest) * radius
            context.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)), with: .color(Color(red: 0.55, green: 1, blue: 0.6)))
        }
    }
}
