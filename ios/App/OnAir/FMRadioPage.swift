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
    @AppStorage("fmMemories") private var memoriesText = ""
    private let tick = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    private var locked: Bool { receiver.status.running && fm.state == 2 }
    private var memories: [Double] {
        let saved = memoriesText.split(separator: ",").map { Double($0) ?? 0 }
        return (0..<6).map { $0 < saved.count ? saved[$0] : 0 }
    }

    var body: some View {
        VStack(spacing: 14) {
            display
            HStack(spacing: 12) {
                NeedleMeter(title: "SIGNAL", value: receiver.status.running ? min(max(fm.snrDb / 60, 0), 1) : 0, scale: ["0", "20", "40", "60"])
                lamps
            }
            .frame(height: 104)
            BandScale(mhz: receiver.status.mhz, lowMhz: 87.5, highMhz: 108, stepMhz: Self.step, tune: receiver.tune(mhz:))
                .frame(height: 62)
            HStack(spacing: 16) {
                memoryColumn(0..<3)
                TuningKnob(stepsPerTurn: 40) { steps in
                    receiver.tune(mhz: min(max(receiver.status.mhz + Double(steps) * Self.step, 87.5), 108))
                }
                memoryColumn(3..<6)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(14)
        .background(RadioTheme.panel)
        .onAppear(perform: load)
        .onReceive(tick) { _ in load() }
    }

    private var display: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "%.1f", receiver.status.mhz))
                    .font(.system(size: 54, weight: .light, design: .rounded).monospacedDigit())
                Text("MHz").font(.system(size: 14, weight: .medium, design: .rounded))
                Spacer()
                Text(locked && !fm.station.isEmpty ? fm.station : "· · · · ·")
                    .font(.system(size: 21, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundStyle(RadioTheme.amber)
            .shadow(color: RadioTheme.amber.opacity(0.65), radius: 9)
            Text(displayLine)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(RadioTheme.amber.opacity(0.75))
                .lineLimit(2, reservesSpace: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RadioTheme.glass)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.25), lineWidth: 1))
    }

    private var displayLine: String {
        guard receiver.status.running else { return "Press play" }
        if !fm.text.isEmpty { return fm.text }
        if !fm.programme.isEmpty { return fm.programme }
        return locked ? "" : "Searching…"
    }

    private var lamps: some View {
        VStack(alignment: .leading, spacing: 11) {
            RadioLamp(label: "LOCK", lit: locked, colour: .green)
            RadioLamp(label: "STEREO", lit: locked && fm.stereo, colour: .red)
            RadioLamp(label: "RDS", lit: locked && fm.rds)
            RadioLamp(label: "TRAFFIC", lit: locked && fm.traffic)
        }
        .frame(width: 92, alignment: .leading)
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

    private func load() {
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

    var body: some View {
        VStack(spacing: 1) {
            Text(String(number)).font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
            Text(mhz > 0 ? String(format: "%.1f", mhz) : "—")
                .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(mhz > 0 ? RadioTheme.amber : Color(white: 0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(white: 0.3), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: recall)
        .onLongPressGesture {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            save()
        }
    }
}
