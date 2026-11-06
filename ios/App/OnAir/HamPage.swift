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
    case usb = "USB", lsb = "LSB", cw = "CW", am = "AM", fm = "FM"
    var id: Self { self }
    var demod: Int32 { switch self { case .fm: 0; case .am: 2; case .usb: 3; case .lsb: 4; case .cw: 5 } }
}

private struct General: Decodable {
    var demod = 3
    var width = 2700.0
    var levelDb = -120.0
    var noiseDb = -120.0
    var snrDb = 0.0
    var squelchOpen = false
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
    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    private static let digital = ["FT8", "FT4", "WSPR", "JS8Call", "PSK31", "RTTY", "CW", "SSTV", "Olivia"]

    private var isVoice: Bool { receiver.status.mode == "General receiver" }

    /// S1 is -121 dBm and each S unit 6 dB, S9 at -73: a fair reading of dBFS on an unknown front end, shown as a position on the scale.
    private var sMeter: Double { min(max((general.levelDb + 110) / 80, 0), 1) }

    var body: some View {
        FacePlate {
            VStack(spacing: 8) {
                GlassWindow(corner: 6) {
                    SpectrumMetalView(renderer: spectrum)
                }
                .frame(height: 110)
                vfo
                bands
                modes
                if isVoice {
                    voiceControls
                } else {
                    decodeLog
                }
                transmitKey
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .sheet(isPresented: $showTransmit) {
            TransmitSheet(receiver: receiver)
        }
        .onAppear(perform: load)
        .onReceive(tick) { _ in load() }
    }

    private var vfo: some View {
        HStack(spacing: 8) {
            GlassWindow(corner: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.3f", receiver.status.mhz))
                        .font(.system(size: 34, weight: .medium, design: .monospaced))
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
        .frame(height: 76)
    }

    private var bands: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(HamBand.all) { band in
                    HardwareKey(lit: isOn(band), led: Rig.lcd, action: { pick(band) }) {
                        EngravedLabel(text: band.name, size: 10)
                    }
                    .frame(width: 46)
                }
            }
        }
        .frame(height: 42)
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(VoiceMode.allCases) { mode in
                    HardwareKey(lit: isVoice && Int32(general.demod) == mode.demod, led: .green, action: { select(voice: mode) }) {
                        EngravedLabel(text: mode.rawValue, size: 9)
                    }
                    .frame(width: 52)
                }
                ForEach(Self.digital, id: \.self) { name in
                    HardwareKey(lit: receiver.status.mode == name, led: .green, action: { select(digital: name) }) {
                        EngravedLabel(text: name.uppercased(), size: 8)
                    }
                    .frame(width: 68)
                }
            }
        }
        .frame(height: 42)
    }

    private func select(voice mode: VoiceMode) {
        if !isVoice { _ = onair_mode_select_named("General receiver") }
        onair_general_set(mode.demod, 0)
        receiver.refresh()
    }

    private func select(digital name: String) {
        _ = onair_mode_select_named(name)
        receiver.refresh()
    }

    private var voiceControls: some View {
        GlassWindow(corner: 6) {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(format: "FILTER %.1f kHz", general.width / 1000)).font(.system(size: 13, design: .monospaced)).foregroundStyle(Rig.lcd)
                HStack(spacing: 4) {
                    ForEach([500.0, 1800, 2400, 2700, 3000, 6000], id: \.self) { width in
                        HardwareKey(lit: abs(general.width - width) < 1, led: Rig.lcd, action: { onair_general_set(Int32(general.demod), width) }) {
                            EngravedLabel(text: width >= 1000 ? String(format: "%.1f", width / 1000) : "500", size: 8)
                        }
                    }
                }
                Text(general.squelchOpen ? "SIGNAL" : "SQUELCH CLOSED").font(.system(size: 10, design: .monospaced)).foregroundStyle(Rig.lcd.opacity(0.65))
            }
            .padding(9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var decodeLog: some View {
        GlassWindow(corner: 6) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    let table = results.tables?.first { !$0.rows.isEmpty }
                    if let table {
                        ForEach(Array(table.rows.suffix(120).reversed().enumerated()), id: \.offset) { _, row in
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
        if !isVoice, let text = onair_results_json() {
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
    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

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
                EngravedLabel(text: status.running ? String(format: "ON AIR %.0f s  STOP", status.seconds) : armed ? "SEND" : "NOT ARMED", size: 11)
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
                    var request = OnAirTxRequest(mhz: receiver.status.mhz, gainDb: gain, seconds: 15, callsign: call, grid: locator, text: message, dest: nil, kind: text.isEmpty ? 0 : 2, wpm: 20, iqPath: nil)
                    return onair_tx_start(&request, &err, Int32(err.count))
                }
            }
        }
        if !ok { problem = String(cString: err) }
    }
}
