import AVFoundation
import AVKit
import OnAirCore
import SwiftUI

private func decode<T: Decodable>(_ type: T.Type, _ text: UnsafePointer<CChar>?) -> T? {
    guard let text else { return nil }
    return try? JSONDecoder().decode(type, from: Data(String(cString: text).utf8))
}

/// The settings that apply on iPhone, generated from OnAir's settings table.
struct SettingsPage: View {
    struct Row: Decodable, Identifiable {
        var id: String { key }
        let key, category, label, help, kind: String
        var value: Double
        var text: String
        let lo, hi: Double
        let choices: [String]
    }

    /// One category, or nil for all of them.
    let only: String?
    @State private var rows: [Row] = []
    @State private var query = ""
    @State private var outputName = ""

    private var shown: [Row] {
        rows.filter { row in
            (only == nil || row.category == only) &&
                (query.isEmpty || row.label.localizedCaseInsensitiveContains(query) || row.help.localizedCaseInsensitiveContains(query))
        }
    }

    private var categories: [String] {
        shown.reduce(into: []) { if !$0.contains($1.category) { $0.append($1.category) } }
    }

    var body: some View {
        PanelPage {
            if only == nil {
                GlassWindow(corner: 6) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(RadioTheme.amber)
                        TextField("", text: $query, prompt: Text("SEARCH SETTINGS").foregroundStyle(RadioTheme.amber.opacity(0.4)))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(RadioTheme.amber)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(9)
                }
            }
            if only == nil {
                PanelSection(title: "Sound output") {
                    PanelRow(label: "Output", help: outputName) {
                        SoundRoutePicker().frame(width: 44, height: 44)
                    }
                }
            }
            ForEach(categories, id: \.self) { category in
                PanelSection(title: only == nil ? category : "") {
                    ForEach(shown.filter { $0.category == category }) { row in
                        SettingRow(row: row) { load() }
                    }
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        rows = decode([Row].self, onair_settings_json()) ?? []
        outputName = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? ""
    }
}

/// Apple's own list of outputs: speaker, headphones, Bluetooth, AirPlay.
private struct SoundRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor(RadioTheme.amber)
        view.activeTintColor = UIColor(RadioTheme.amber)
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

private struct SettingRow: View {
    let row: SettingsPage.Row
    let changed: () -> Void
    @State private var number = 0.0
    @State private var text = ""

    var body: some View {
        control
            .onAppear {
                number = row.value
                text = row.text
            }
    }

    @ViewBuilder private var control: some View {
        switch row.kind {
        case "bool":
            PanelRow(label: row.label) {
                RockerSwitch(isOn: Binding(get: { row.value != 0 }, set: { set($0 ? 1 : 0) }))
            }
        case "choice":
            PanelRow(label: row.label) {
                SelectorWindow(selected: row.choices.indices.contains(Int(row.value)) ? row.choices[Int(row.value)] : "", options: row.choices) { set(Double($0)) }
            }
        case "text":
            PanelRow(label: row.label) {
                GlassWindow(corner: 4) {
                    TextField("", text: $text)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(RadioTheme.amber)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(7)
                        .frame(width: 150)
                        .onSubmit {
                            onair_setting_set_text(row.key, text)
                            changed()
                        }
                }
            }
        default:
            if row.hi > row.lo {
                VStack(spacing: 0) {
                    PanelRow(label: row.label) {
                        Text(row.kind == "int" ? String(Int(number)) : String(format: "%.2f", number))
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(RadioTheme.amber)
                    }
                    Fader(value: $number, range: row.lo...row.hi, step: row.kind == "int" ? 1 : 0) { set(number) }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                }
            } else {
                PanelRow(label: row.label) {
                    GlassWindow(corner: 4) {
                        TextField("", value: $number, format: .number)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(RadioTheme.amber)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .padding(7)
                            .frame(width: 110)
                            .onSubmit { set(number) }
                    }
                }
            }
        }
    }

    private func set(_ value: Double) {
        onair_setting_set(row.key, value)
        changed()
    }
}

/// Gain and the sample corrections.
struct GainPage: View {
    private struct State: Decodable {
        let radio, generic: Bool
        let lo, hi: Double
        var db: Double
        var agc, iq: Bool
        var dc: Int
    }

    @SwiftUI.State private var state: State?
    @SwiftUI.State private var db = 0.0

    var body: some View {
        PanelPage {
            if let state, state.radio {
                PanelSection(title: "Gain") {
                    if state.generic {
                        PanelRow(label: "Gain") {
                            Text("\(Int(db)) dB").font(.system(size: 15, weight: .medium, design: .monospaced)).foregroundStyle(RadioTheme.amber)
                        }
                        Fader(value: $db, range: state.lo...state.hi, step: 1) {
                            onair_gain_set(db)
                            load()
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                    }
                    PanelRow(label: "Automatic gain") {
                        RockerSwitch(isOn: Binding(get: { state.agc }, set: { onair_agc_set($0); load() }))
                    }
                }
                PanelSection(title: "Corrections") {
                    PanelRow(label: "DC spike") {
                        SelectorWindow(selected: ["Leave", "Remove", "Tune beside it"][min(max(state.dc, 0), 2)], options: ["Leave", "Remove", "Tune beside it"]) { onair_dc_mode_set(Int32($0)); load() }
                    }
                    PanelRow(label: "IQ correction") {
                        RockerSwitch(isOn: Binding(get: { state.iq }, set: { onair_iq_fix_set($0); load() }))
                    }
                }
            } else {
                PanelSection(title: "Gain") {
                    PanelRow(label: "Gain applies to radios", help: "Choose a radio under Source.") { EmptyView() }
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        state = decode(State.self, onair_gain_json())
        if let state { db = state.db }
    }
}

/// The selected radio's own settings, as its driver lists them.
struct RadioSettingsPage: View {
    private struct Row: Decodable, Identifiable {
        var id: String { key }
        let key, label, help, kind, value, unit: String
        let lo, hi, step: Double
        let values, names: [String]
    }

    @State private var rows: [Row] = []
    @State private var numbers: [String: Double] = [:]

    var body: some View {
        PanelPage {
            if rows.isEmpty {
                PanelSection(title: "Radio") {
                    PanelRow(label: "No settings", help: "This source has no settings of its own.") { EmptyView() }
                }
            } else {
                PanelSection(title: "Radio") {
                    ForEach(rows) { row in control(row) }
                }
            }
        }
        .onAppear(perform: load)
    }

    @ViewBuilder private func control(_ row: Row) -> some View {
        switch row.kind {
        case "bool":
            PanelRow(label: row.label, help: row.help) {
                RockerSwitch(isOn: Binding(get: { row.value == "1" }, set: { set(row, $0 ? "1" : "0") }))
            }
        case "choice":
            PanelRow(label: row.label, help: row.help) {
                let index = row.values.firstIndex(of: row.value) ?? 0
                SelectorWindow(selected: row.names.indices.contains(index) ? row.names[index] : row.value, options: row.names) { set(row, row.values[$0]) }
            }
        default:
            let number = Binding(get: { numbers[row.key] ?? Double(row.value) ?? row.lo }, set: { numbers[row.key] = $0 })
            VStack(spacing: 0) {
                PanelRow(label: row.label, help: row.help) {
                    Text(String(format: "%g %@", number.wrappedValue, row.unit)).font(.system(size: 13, design: .monospaced)).foregroundStyle(RadioTheme.amber)
                }
                if row.hi > row.lo {
                    Fader(value: number, range: row.lo...row.hi, step: row.step) { set(row, String(number.wrappedValue)) }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                }
            }
        }
    }

    private func set(_ row: Row, _ value: String) {
        onair_radio_setting_set(row.key, value)
        load()
    }

    private func load() { rows = decode([Row].self, onair_radio_settings_json()) ?? [] }
}
