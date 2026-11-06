import Accelerate
import OnAirCore
import SwiftUI

/// FM as a radio: a lit display, a real meter, a sliding band scale, a heavy knob and memory buttons.
struct FMRadioPage: View {
    private struct FM: Decodable {
        var state = 0
        var station = ""
        var text = ""
        var programme = ""
        var stereo = false
        var snrDb = 0.0
        var levelDbfs = -120.0
        var rds = false
        var rdsOk = 0.0
        var traffic = false
    }

    private static let step = 0.1

    let receiver: Receiver
    @State private var fm = FM()
    @State private var audioLevel = 0.0
    @AppStorage("fmMemories") private var memoriesText = ""
    private let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    private var locked: Bool { receiver.status.running && fm.state == 2 }
    private var memories: [Double] {
        let saved = memoriesText.split(separator: ",").map { Double($0) ?? 0 }
        return (0..<6).map { $0 < saved.count ? saved[$0] : 0 }
    }

    var body: some View {
        FacePlate {
            VStack(spacing: 12) {
                display
                HStack(spacing: 8) {
                    NeedleMeter(title: "SIGNAL", value: receiver.status.running ? min(max(fm.snrDb / 60, 0), 1) : 0, scale: ["0", "20", "40", "60"])
                    NeedleMeter(title: "VU", value: receiver.status.running ? audioLevel : 0, scale: ["-30", "-20", "-10", "0"])
                }
                .frame(height: 92)
                lamps
                BandScale(mhz: receiver.status.mhz, lowMhz: 87.5, highMhz: 108, stepMhz: Self.step, tune: receiver.tune(mhz:))
                    .frame(height: 56)
                HStack(spacing: 14) {
                    memoryColumn(0..<3)
                    VStack(spacing: 3) {
                        TuningKnob(stepsPerTurn: 40) { steps in
                            receiver.tune(mhz: min(max(receiver.status.mhz + Double(steps) * Self.step, 87.5), 108))
                        }
                        EngravedLabel(text: "TUNING")
                    }
                    memoryColumn(3..<6)
                }
                .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .onAppear {
            TiltLight.shared.start()
            load()
        }
        .onReceive(tick) { _ in load() }
    }

    private var display: some View {
        GlassWindow(corner: 8) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "%.3f", receiver.status.mhz))
                        .font(.system(size: 42, weight: .light, design: .monospaced))
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 6)
                    Text(locked && !fm.station.isEmpty ? fm.station : "· · · · ·")
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .foregroundStyle(RadioTheme.amber)
                .shadow(color: RadioTheme.amber.opacity(0.8), radius: 8)
                Text(displayLine)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(RadioTheme.amber.opacity(0.75))
                    .lineLimit(2, reservesSpace: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var displayLine: String {
        guard receiver.status.running else { return "Press play" }
        if !fm.text.isEmpty { return fm.text }
        if !fm.programme.isEmpty { return fm.programme }
        return locked ? "" : "Searching…"
    }

    private var lamps: some View {
        GlassWindow(corner: 6) {
            HStack {
                RadioLamp(label: "LOCK", lit: locked, colour: .green)
                Spacer()
                RadioLamp(label: "STEREO", lit: locked && fm.stereo, colour: .red)
                Spacer()
                RadioLamp(label: "RDS", lit: locked && fm.rds)
                Spacer()
                RadioLamp(label: "TRAFFIC", lit: locked && fm.traffic)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
        }
    }

    private func memoryColumn(_ range: Range<Int>) -> some View {
        VStack(spacing: 10) {
            ForEach(range, id: \.self) { index in
                MemoryButton(number: index + 1, mhz: memories[index]) {
                    if memories[index] > 0 { receiver.tune(mhz: memories[index]) }
                } save: {
                    var all = memories
                    all[index] = receiver.status.mhz
                    memoriesText = all.map { String($0) }.joined(separator: ",")
                }
            }
        }
        .frame(width: 66)
    }

    /// The sound's level over the last moment: 0 at -30 dB, 1 at full scale.
    private func measureAudio() {
        var stereo = [Float](repeating: 0, count: 4096)
        onair_audio_recent(&stereo, 2048)
        let db = 20 * log10(max(vDSP.rootMeanSquare(stereo), 1e-6))
        audioLevel = min(max(Double(db + 30) / 30, 0), 1)
    }

    private func load() {
        measureAudio()
        guard let text = onair_fm_json() else { return }
        if let new = try? JSONDecoder().decode(FM.self, from: Data(String(cString: text).utf8)) { fm = new }
    }
}

/// Tap to recall, hold to store, like the push buttons on a car radio.
private struct MemoryButton: View {
    let number: Int
    let mhz: Double
    let recall: () -> Void
    let save: () -> Void

    /// As many decimals as the frequency has, and at least one.
    private static func short(_ mhz: Double) -> String {
        var text = String(format: "%.3f", mhz)
        while text.hasSuffix("0"), !text.hasSuffix(".0") { text.removeLast() }
        return text
    }

    var body: some View {
        HardwareKey(lit: mhz > 0, action: recall) {
            VStack(spacing: 0) {
                EngravedLabel(text: String(number), size: 8)
                Text(mhz > 0 ? Self.short(mhz) : "")
                    .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color(white: 0.09))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .onLongPressGesture {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            save()
        }
    }
}
