import OnAirCore
import SwiftUI

private func decode<T: Decodable>(_ type: T.Type, _ text: UnsafePointer<CChar>?) -> T? {
    guard let text else { return nil }
    return try? JSONDecoder().decode(type, from: Data(String(cString: text).utf8))
}

/// Every setting OnAir has that applies here, generated from its settings table. A new upstream setting appears on its own.
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
        List {
            ForEach(categories, id: \.self) { category in
                Section(only == nil ? category : "") {
                    ForEach(shown.filter { $0.category == category }) { row in
                        SettingRow(row: row) { load() }
                    }
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search settings")
        .onAppear(perform: load)
    }

    private func load() { rows = decode([Row].self, onair_settings_json()) ?? [] }
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
            Toggle(row.label, isOn: Binding(get: { row.value != 0 }, set: { set($0 ? 1 : 0) }))
        case "choice":
            Picker(row.label, selection: Binding(get: { Int(row.value) }, set: { set(Double($0)) })) {
                ForEach(Array(row.choices.enumerated()), id: \.offset) { index, name in Text(name).tag(index) }
            }
        case "text":
            LabeledContent(row.label) {
                TextField("", text: $text)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit {
                        onair_setting_set_text(row.key, text)
                        changed()
                    }
            }
        default:
            if row.hi > row.lo {
                VStack(alignment: .leading) {
                    LabeledContent(row.label, value: row.kind == "int" ? String(Int(number)) : String(format: "%.2f", number))
                    Slider(value: $number, in: row.lo...row.hi, step: row.kind == "int" ? 1 : (row.hi - row.lo) / 200) { editing in
                        if !editing { set(number) }
                    }
                }
            } else {
                LabeledContent(row.label) {
                    TextField("", value: $number, format: .number)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { set(number) }
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
        List {
            if let state, state.radio {
                Section("Gain") {
                    if state.generic {
                        VStack(alignment: .leading) {
                            LabeledContent("Gain", value: "\(Int(db)) dB")
                            Slider(value: $db, in: state.lo...state.hi, step: 1) { editing in
                                if !editing {
                                    onair_gain_set(db)
                                    load()
                                }
                            }
                        }
                    }
                    Toggle("Automatic gain", isOn: Binding(get: { state.agc }, set: { onair_agc_set($0); load() }))
                }
                Section("Corrections") {
                    Picker("DC spike", selection: Binding(get: { state.dc }, set: { onair_dc_mode_set(Int32($0)); load() })) {
                        Text("Leave").tag(0)
                        Text("Remove").tag(1)
                        Text("Tune beside it").tag(2)
                    }
                    Toggle("IQ correction", isOn: Binding(get: { state.iq }, set: { onair_iq_fix_set($0); load() }))
                }
            } else {
                Text("Gain applies to radios. Choose one under Source.").foregroundStyle(.secondary)
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
        List {
            if rows.isEmpty {
                Text("This source has no settings of its own.").foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                Section {
                    control(row)
                } footer: {
                    if !row.help.isEmpty { Text(row.help) }
                }
            }
        }
        .onAppear(perform: load)
    }

    @ViewBuilder private func control(_ row: Row) -> some View {
        switch row.kind {
        case "bool":
            Toggle(row.label, isOn: Binding(get: { row.value == "1" }, set: { set(row, $0 ? "1" : "0") }))
        case "choice":
            Picker(row.label, selection: Binding(get: { row.value }, set: { set(row, $0) })) {
                ForEach(Array(row.values.enumerated()), id: \.offset) { index, value in Text(row.names[index]).tag(value) }
            }
        default:
            let number = Binding(get: { numbers[row.key] ?? Double(row.value) ?? row.lo }, set: { numbers[row.key] = $0 })
            VStack(alignment: .leading) {
                LabeledContent(row.label, value: String(format: "%g %@", number.wrappedValue, row.unit))
                if row.hi > row.lo {
                    Slider(value: number, in: row.lo...row.hi) { editing in
                        if !editing { set(row, String(number.wrappedValue)) }
                    }
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
