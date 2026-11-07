import OnAirCore
import SwiftUI

private enum Rig {
    static let lcd = Color(red: 0.62, green: 0.86, blue: 1.0)
    static let onAir = Color(red: 1, green: 0.16, blue: 0.1)
}

/// The amateur bands, with where each digital mode's calling frequency sits.
private struct HamBand: Identifiable {
    var id: String { name }
    let name: String
    let voice, ft8: Double   // MHz
    var sideband: Int { voice < 10 ? 4 : 3 }   // LSB below 10 MHz, USB above

    static let all = [
        HamBand(name: "160", voice: 1.9, ft8: 1.840), HamBand(name: "80", voice: 3.75, ft8: 3.573), HamBand(name: "40", voice: 7.15, ft8: 7.074),
        HamBand(name: "30", voice: 10.125, ft8: 10.136), HamBand(name: "20", voice: 14.2, ft8: 14.074), HamBand(name: "17", voice: 18.13, ft8: 18.100),
        HamBand(name: "15", voice: 21.3, ft8: 21.074), HamBand(name: "12", voice: 24.95, ft8: 24.915), HamBand(name: "10", voice: 28.5, ft8: 28.074),
        HamBand(name: "6", voice: 50.15, ft8: 50.313), HamBand(name: "2", voice: 144.2, ft8: 144.174), HamBand(name: "70", voice: 432.2, ft8: 432.174),
    ]
}

private enum VoiceMode: String, CaseIterable, Identifiable {
    case usb = "USB", lsb = "LSB", cw = "CW", am = "AM", fm = "NFM", wfm = "WFM"
    var id: Self { self }
    var demod: Int32 { switch self { case .fm: 0; case .wfm: 1; case .am: 2; case .usb: 3; case .lsb: 4; case .cw: 5 } }
    /// The step that lands on the next channel of what this is used for.
    var stepHz: Double { switch self { case .wfm: 100_000; case .fm: 12_500; case .am: 5000; case .cw: 100; case .usb, .lsb: 1000 } }
}

/// A shortcut on the rig: where a demodulator is used.
private struct RigBand: Identifiable {
    var id: String { name }
    let name: String
    let mhz: Double

    static let cw = [RigBand(name: "160", mhz: 1.83), RigBand(name: "80", mhz: 3.53), RigBand(name: "40", mhz: 7.03), RigBand(name: "30", mhz: 10.12), RigBand(name: "20", mhz: 14.03), RigBand(name: "17", mhz: 18.08), RigBand(name: "15", mhz: 21.03), RigBand(name: "12", mhz: 24.91), RigBand(name: "10", mhz: 28.03), RigBand(name: "6", mhz: 50.09), RigBand(name: "2", mhz: 144.05), RigBand(name: "70", mhz: 432.05)]
    static let nfm = [RigBand(name: "10M", mhz: 29.6), RigBand(name: "6M", mhz: 52.525), RigBand(name: "2M", mhz: 145.5), RigBand(name: "MARINE", mhz: 156.8), RigBand(name: "70CM", mhz: 439.0), RigBand(name: "PMR", mhz: 446.1), RigBand(name: "UHF CB", mhz: 477.0)]
    static let wfm = [RigBand(name: "88", mhz: 88.1), RigBand(name: "92", mhz: 92.1), RigBand(name: "96", mhz: 96.1), RigBand(name: "100", mhz: 100.1), RigBand(name: "104", mhz: 104.1), RigBand(name: "107", mhz: 107.1)]
}

private struct General: Decodable {
    var demod = 3
    var width = 2700.0
    var levelDb = -120.0
    var noiseDb = -120.0
    var snrDb = 0.0
    var squelchOpen = false
    var presets: [Double] = []
}

private struct Shortwave: Decodable {
    struct Decoder: Decodable, Identifiable {
        let id: Int32
        let name, group: String
        let on, picture: Bool
    }

    struct Band: Decodable, Identifiable {
        var id: String { name }
        let name: String
        let khz: Double
    }

    var auto = false
    var decoders: [Decoder] = []
    var bands: [Band] = []
}

private struct DecodeTable: Decodable {
    struct Table: Decodable {
        let name: String
        let cols: [String]
        let rows: [[String]]
    }

    var summary: String?
    var tables: [Table]?
}

/// A modern HF rig: panadapter, VFO, S-meter, bands and modes, a log of what was decoded, and a guarded transmit control.
struct HamPage: View {
    let receiver: Receiver
    let spectrum: SpectrumRenderer
    @State private var general = General()
    @State private var results = DecodeTable()
    @State private var showTransmit = false
    @AppStorage("rigStepHz") private var stepHz = 1000.0
    @State private var shortwave = Shortwave()
    @State private var showPicture = false
    @State private var tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    private static let steps: [Double] = [100, 1000, 5000, 12500, 25000, 100_000]
    private static let digital = ["FT8", "FT4", "WSPR", "JS8Call", "PSK31", "RTTY", "CW", "SSTV", "Olivia"]
    private static let decoderGroups = ["Text", "Weak signal", "Images", "Data links", "Other"]

    private var isShortwave: Bool { receiver.status.family == OnAirFamily.shortwave }
    private var isVoice: Bool { receiver.status.mode == "General receiver" || isShortwave }

    /// S1 is -121 dBm and each S unit 6 dB, S9 at -73: a fair reading of dBFS on an unknown front end, shown as a position on the scale.
    private var sMeter: Double { min(max((general.levelDb + 110) / 80, 0), 1) }

    var body: some View {
        FacePlate {
            VStack(spacing: 6) {
                GlassWindow(corner: 6) {
                    SpectrumMetalView(renderer: spectrum)
                        .overlay { FilterBox(receiver: receiver, spectrum: spectrum) }
                }
                .frame(height: isVoice ? 84 : 110)
                vfo
                if isVoice {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 6) {
                            if isShortwave {
                                demodBands
                                shortwaveDemods
                                filters
                                tuning
                                decoderKeys
                                decodedText
                                Color.clear.frame(height: 24)   // clear of the settings tab
                            } else {
                                demodBands
                                modes
                                filters
                                tuning
                                transmitKey
                            }
                        }
                    }
                } else {
                    bands
                    modes
                    decodeLog
                    transmitKey
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 28)   // clear of the drawer tabs on the right edge
            .padding(.vertical, 10)
        }
        .sheet(isPresented: $showTransmit) {
            TransmitSheet(receiver: receiver)
        }
        .sheet(isPresented: $showPicture) {
            PicturePage(receiver: receiver)
        }
        .onAppear(perform: load)
        .onReceive(tick) { _ in load() }
    }

    private var vfo: some View {
        HStack(spacing: 8) {
            GlassWindow(corner: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(vfoText)
                        .font(.system(size: 30, weight: .medium, design: .monospaced))
                        .foregroundStyle(Rig.lcd)
                        .shadow(color: Rig.lcd.opacity(0.7), radius: 7)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(receiver.status.mode.uppercased())
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Rig.lcd.opacity(0.7))
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            NeedleMeter(title: "S", value: receiver.status.running ? sMeter : 0, scale: ["1", "5", "9", "+40"])
                .frame(width: 138)
        }
        .frame(height: 66)
    }

    /// As the top display: more digits only when tuned between them.
    private var vfoText: String { Receiver.frequencyText(mhz: receiver.status.mhz).replacingOccurrences(of: " MHz", with: "") }

    private func keyGrid(_ columns: Int) -> [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 4), count: columns) }

    private var bands: some View {
        LazyVGrid(columns: keyGrid(6), spacing: 4) {
            ForEach(HamBand.all) { band in
                HardwareKey(lit: isOn(band), led: Rig.lcd, action: { pick(band) }) {
                    EngravedLabel(text: band.name, size: 10)
                }
                .frame(height: 32)
                .opacity(receiver.canReach(mhz: band.ft8) ? 1 : 0.25)
            }
        }
    }

    private func isOn(_ band: HamBand) -> Bool {
        let mhz = receiver.status.mhz
        return mhz >= band.voice * 0.9 && mhz <= band.voice * 1.12
    }

    private func pick(_ band: HamBand) {
        if isVoice {
            onair_general_set(Int32(band.sideband), 0)
            receiver.tune(mhz: band.voice)
        } else {
            receiver.tune(mhz: band.ft8)
        }
    }

    private var modes: some View {
        LazyVGrid(columns: keyGrid(5), spacing: 4) {
            ForEach(VoiceMode.allCases) { mode in
                HardwareKey(lit: isVoice && Int32(general.demod) == mode.demod, led: .green, action: { select(voice: mode) }) {
                    EngravedLabel(text: mode.rawValue, size: 9)
                }
                .frame(height: 32)
            }
            ForEach(Self.digital, id: \.self) { name in
                HardwareKey(lit: receiver.status.mode == name, led: .green, action: { select(digital: name) }) {
                    EngravedLabel(text: name == "CW" ? "MORSE" : name.uppercased(), size: 8)
                }
                .frame(height: 32)
            }
        }
    }

    private func select(voice mode: VoiceMode) {
        if !isVoice { _ = onair_mode_select_named("General receiver") }
        onair_general_set(mode.demod, 0)
        stepHz = mode.stepHz
        receiver.refresh()
    }

    private func select(digital name: String) {
        _ = onair_mode_select_named(name)
        receiver.refresh()
    }

    private func hzText(_ hz: Double) -> String {
        if hz >= 1000 {
            let khz = hz / 1000
            return khz == khz.rounded() ? String(format: "%.0fk", khz) : String(format: "%gk", khz)
        }
        return String(format: "%.0f", hz)
    }

    private var voiceMode: VoiceMode { VoiceMode.allCases.first { $0.demod == Int32(general.demod) } ?? .usb }

    private var voiceBands: [RigBand] {
        switch voiceMode {
        case .usb, .lsb: HamBand.all.map { RigBand(name: $0.name, mhz: $0.voice) }
        case .cw: RigBand.cw
        case .fm: RigBand.nfm
        case .wfm: RigBand.wfm
        case .am:
            [RigBand(name: "MW", mhz: 0.999)] + shortwave.bands.map { RigBand(name: $0.name, mhz: $0.khz / 1000) } + [RigBand(name: "AIR", mhz: 120.5)]
        }
    }

    /// The band keys of the demodulator in use. What the radio cannot tune is dimmed; a tap still says why.
    private var demodBands: some View {
        LazyVGrid(columns: keyGrid(6), spacing: 4) {
            ForEach(voiceBands) { band in
                HardwareKey(lit: abs(receiver.status.mhz - band.mhz) < max(band.mhz * 0.03, 0.15), led: Rig.lcd, action: { tune(band) }) {
                    EngravedLabel(text: band.name, size: band.name.count > 3 ? 7 : 9)
                }
                .frame(height: 30)
                .opacity(receiver.canReach(mhz: band.mhz) ? 1 : 0.25)
            }
        }
    }

    private func tune(_ band: RigBand) {
        if voiceMode == .usb || voiceMode == .lsb { onair_general_set(band.mhz < 10 ? 4 : 3, 0) }   // LSB below 10 MHz, USB above
        if isShortwave { onair_sw_tune_khz(band.mhz * 1000) } else { receiver.tune(mhz: band.mhz) }
        receiver.refresh()
    }

    private var shortwaveDemods: some View {
        LazyVGrid(columns: keyGrid(6), spacing: 4) {
            ForEach([VoiceMode.am, .usb, .lsb, .cw, .fm, .wfm]) { mode in
                HardwareKey(lit: Int32(general.demod) == mode.demod, led: .green, action: { select(voice: mode) }) {
                    EngravedLabel(text: mode.rawValue, size: 9)
                }
                .frame(height: 30)
            }
        }
    }

    private var decoderKeys: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                EngravedLabel(text: "DECODERS", size: 8)
                Spacer()
                HardwareKey(lit: shortwave.auto, led: .green, action: { onair_sw_auto(!shortwave.auto) }) { EngravedLabel(text: "AUTO", size: 8) }
                    .frame(width: 62, height: 28)
                HardwareKey(action: { onair_sw_stop_all() }) { EngravedLabel(text: "NONE", size: 8) }
                    .frame(width: 62, height: 28)
                if shortwave.decoders.contains(where: { $0.on && $0.picture }) {
                    HardwareKey(action: { showPicture = true }) { EngravedLabel(text: "PICTURE", size: 8) }
                        .frame(width: 66, height: 28)
                }
            }
            ForEach(Self.decoderGroups, id: \.self) { group in
                let keys = shortwave.decoders.filter { $0.group == group }
                if !keys.isEmpty {
                    EngravedLabel(text: group.uppercased(), size: 7)
                    LazyVGrid(columns: keyGrid(4), spacing: 4) {
                        ForEach(keys) { decoder in
                            HardwareKey(lit: decoder.on, led: .green, action: { onair_sw_press(decoder.id) }) {
                                EngravedLabel(text: decoder.name.uppercased(), size: 7)
                            }
                            .frame(height: 30)
                        }
                    }
                }
            }
        }
    }

    /// What each running decoder last produced.
    private var decodedText: some View {
        let table = results.tables?.first { $0.name == "Decoders" }
        let name = table?.cols.firstIndex(of: "Decoder"), state = table?.cols.firstIndex(of: "State"), text = table?.cols.firstIndex(of: "Text")
        return GlassWindow(corner: 6) {
            VStack(alignment: .leading, spacing: 3) {
                if let table, let name, let state, let text, !table.rows.isEmpty {
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                        Text("\(row[name])  \(row[state])  \(row[text])")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Rig.lcd)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text(receiver.status.running ? "Press a decoder or AUTO" : "Press power to start")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Rig.lcd.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(8)
        }
    }

    /// The widths the core offers for this demodulator.
    private var filters: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                EngravedLabel(text: "FILTER", size: 8)
                Text(general.width >= 1000 ? String(format: "%g kHz", general.width / 1000) : String(format: "%.0f Hz", general.width))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Rig.lcd)
                Spacer()
                Text(general.squelchOpen ? "SIGNAL" : "SQUELCH CLOSED").font(.system(size: 10, design: .monospaced)).foregroundStyle(Rig.lcd.opacity(0.65))
            }
            LazyVGrid(columns: keyGrid(6), spacing: 4) {
                ForEach(general.presets, id: \.self) { width in
                    HardwareKey(lit: abs(general.width - width) < 1, led: Rig.lcd, action: { onair_general_set(Int32(general.demod), width) }) {
                        EngravedLabel(text: hzText(width), size: 8)
                    }
                    .frame(height: 30)
                }
            }
        }
    }

    private var tuning: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                EngravedLabel(text: "TUNING STEP", size: 8)
                LazyVGrid(columns: keyGrid(3), spacing: 4) {
                    ForEach(Self.steps, id: \.self) { step in
                        HardwareKey(lit: stepHz == step, led: Rig.lcd, action: { stepHz = step }) {
                            EngravedLabel(text: hzText(step), size: 8)
                        }
                        .frame(height: 30)
                    }
                }
            }
            TuningKnob(stepsPerTurn: 40) { steps in
                onair_spectrum_scrub(receiver.status.mhz + Double(steps) * stepHz / 1e6)
                receiver.refresh()
            }
            .frame(width: 96, height: 96)
            .padding(.trailing, 10)   // its ring and shadow stand outside the frame; the scroll view would cut them
            .padding(.vertical, 8)
        }
    }

    private var decodeLog: some View {
        GlassWindow(corner: 6) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    let table = results.tables?.first { !$0.rows.isEmpty }
                    if let table {
                        ForEach(Array(table.rows.prefix(120).enumerated()), id: \.offset) { _, row in
                            Text(row.joined(separator: "  "))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(row.joined().contains("CQ") ? Color.green : Rig.lcd)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Text(receiver.status.running ? (results.summary ?? "Listening…") : "Press power to start")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Rig.lcd.opacity(0.7))
                    }
                }
                .padding(8)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var transmitKey: some View {
        HardwareKey(lit: false, led: Rig.onAir, action: { showTransmit = true }) {
            EngravedLabel(text: "TRANSMIT", size: 10)
        }
        .frame(height: 44)
    }

    private func load() {
        if let text = onair_general_json(), let new = try? JSONDecoder().decode(General.self, from: Data(String(cString: text).utf8)) { general = new }
        if isVoice, let text = onair_sw_json(), let new = try? JSONDecoder().decode(Shortwave.self, from: Data(String(cString: text).utf8)) { shortwave = new }
        if !isVoice || isShortwave, let text = onair_results_json() {
            do {
                results = try JSONDecoder().decode(DecodeTable.self, from: Data(String(cString: text).utf8))
            } catch {
                NSLog("OnAirVerify decode failed: %@", String(describing: error))
            }
        }
    }
}

/// Sending takes two deliberate steps: arm it, then hold the key. It always shows what will go out, where, and at what power.
struct TransmitSheet: View {
    private struct Status: Decodable {
        var running = false
        var seconds = 0.0
        var failed = false
        var error = ""
    }

    let receiver: Receiver
    @Environment(\.dismiss) private var dismiss
    @AppStorage("txCallsign") private var callsign = ""
    @AppStorage("txGrid") private var grid = ""
    @AppStorage("txGainDb") private var gain = -30.0
    @State private var text = ""
    @State private var armed = false
    @State private var status = Status()
    @State private var problem = ""
    @State private var tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        PanelPage {
            PanelSection(title: "Transmit") {
                PanelRow(label: receiver.status.mode, help: String(format: "%.3f MHz on %@", receiver.status.mhz, receiver.status.source)) { EmptyView() }
                field("Callsign", $callsign)
                field("Grid", $grid)
                field("Message", $text)
                PanelRow(label: "TX gain") {
                    Text(String(format: "%.0f dB", gain)).font(.system(size: 13, design: .monospaced)).foregroundStyle(RadioTheme.amber)
                }
                Fader(value: $gain, range: -60...0, step: 1) {}
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
            PanelSection(title: "Before you send") {
                PanelRow(label: "You are responsible", help: "Sending needs a licence or permission for this frequency, mode and power. Nothing goes out until you arm it and press SEND.") {
                    RockerSwitch(isOn: $armed)
                }
            }
            if !problem.isEmpty {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
            HardwareKey(lit: status.running, led: .red, action: toggle) {
                EngravedLabel(text: status.running ? String(format: "ON AIR %.0f s  STOP", status.seconds) : armed ? (isVoice ? "TALK" : "SEND") : "NOT ARMED", size: 11)
            }
            .frame(height: 64)
            .disabled(!armed && !status.running)
            .opacity(armed || status.running ? 1 : 0.55)
        }
        .presentationDetents([.large])
        .onReceive(tick) { _ in
            if let json = onair_tx_json(), let new = try? JSONDecoder().decode(Status.self, from: Data(String(cString: json).utf8)) {
                status = new
                if new.failed { problem = new.error }
            }
        }
        .onDisappear { onair_tx_stop() }
    }

    private func field(_ title: String, _ value: Binding<String>) -> some View {
        PanelRow(label: title) {
            GlassWindow(corner: 4) {
                TextField("", text: value)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(RadioTheme.amber)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .padding(7)
                    .frame(width: 170)
            }
        }
    }

    private var isVoice: Bool { receiver.status.mode == "General receiver" }

    /// The transmitter's voice kinds: 0 FM, 1 AM, 2 USB, 3 LSB. The receiver's demodulator says which.
    private var voiceKind: Int32? {
        guard isVoice, let text = onair_general_json(), let g = try? JSONDecoder().decode(General.self, from: Data(String(cString: text).utf8)) else { return nil }
        switch g.demod {
        case 2: return 1
        case 3: return 2
        case 4: return 3
        default: return 0
        }
    }

    private func toggle() {
        if status.running {
            onair_tx_stop()
            return
        }
        problem = ""
        var err = [CChar](repeating: 0, count: 256)
        let ok: Bool = callsign.withCString { call in
            grid.withCString { locator in
                text.withCString { message in
                    var request = OnAirTxRequest(mhz: receiver.status.mhz, gainDb: gain, seconds: isVoice ? 0 : 15, callsign: call, grid: locator, text: message, dest: nil, kind: voiceKind ?? (text.isEmpty ? 0 : 2), wpm: 20, microphone: isVoice, iqPath: nil)
                    return onair_tx_start(&request, &err, Int32(err.count))
                }
            }
        }
        if !ok { problem = String(cString: err) }
    }
}
