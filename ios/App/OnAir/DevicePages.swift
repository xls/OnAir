import OnAirCore
import SwiftUI

/// The radios and sources C++ found, plus adding a network radio.
struct SourcePage: View {
    let receiver: Receiver
    @State private var showAdd = false
    @State private var antenna: Setting?
    @State private var upconverters = Upconverters()

    var body: some View {
        PanelPage {
            PanelSection(title: "Source") {
                ForEach(Array(receiver.devices.enumerated()).filter { !$0.element.hasPrefix("IQ recording") }, id: \.offset) { index, name in
                    Button {
                        onair_device_select(Int32(index))
                        receiver.refresh()
                    } label: {
                        PanelRow(label: name) {
                            Circle()
                                .fill(name == receiver.status.source ? Color.green : Color(white: 0.18))
                                .frame(width: 10, height: 10)
                                .shadow(color: name == receiver.status.source ? .green : .clear, radius: 5)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if let antenna {
                PanelSection(title: "Antenna") {
                    PanelRow(label: "Receive on", help: "Radios with two receivers. Changing it restarts the radio.") {
                        SelectorWindow(selected: antenna.names[antenna.values.firstIndex(of: antenna.value) ?? 0], options: antenna.names) { index in
                            onair_radio_setting_set("antenna", antenna.values[index])
                            loadAntenna()
                        }
                    }
                    ForEach(Array(zip(antenna.values, antenna.names)), id: \.0) { value, name in
                        PanelRow(label: "Ham It Up on \(name)", help: "A 125 MHz up-converter on this antenna: reaches HF, and you still tune the frequency at the antenna.") {
                            RockerSwitch(isOn: Binding(get: { value == "rx1" ? upconverters.rx1 : upconverters.rx2 }, set: { on in
                                onair_antenna_converter_set(value, on)
                                loadAntenna()
                            }))
                        }
                        if value == "rx1" ? upconverters.rx1 : upconverters.rx2 {
                            OscillatorRow(antenna: value, name: name, mhz: value == "rx1" ? upconverters.rx1lo : upconverters.rx2lo, changed: loadAntenna)
                        }
                    }
                }
            }
            HardwareKey(action: { showAdd = true }) {
                EngravedLabel(text: "ADD NETWORK RADIO", size: 9)
            }
            .frame(height: 50)
            RecordingsSection(receiver: receiver)
        }
        .sheet(isPresented: $showAdd) {
            RadioSheet()
        }
        .onAppear(perform: loadAntenna)
        .onChange(of: receiver.status.source) { loadAntenna() }
        .onChange(of: receiver.devices) { loadAntenna() }
    }

    private struct Setting: Decodable {
        let key, value: String
        let values, names: [String]
    }

    private struct Upconverters: Decodable {
        var rx1 = false
        var rx2 = false
        var rx1lo = "125"
        var rx2lo = "125"
    }

    private func loadAntenna() {
        guard let text = onair_radio_settings_json() else { return }
        antenna = (try? JSONDecoder().decode([Setting].self, from: Data(String(cString: text).utf8)))?.first { $0.key == "antenna" }
        if let json = onair_converter_json(), let new = try? JSONDecoder().decode(Upconverters.self, from: Data(String(cString: json).utf8)) { upconverters = new }
    }
}

/// A Ham It Up's own frequency offset, for a tuning error or another converter. Off is the standard 125 MHz.
private struct OscillatorRow: View {
    let antenna, name, mhz: String
    let changed: () -> Void
    @State private var custom = false
    @State private var entry = ""
    @FocusState private var typing: Bool

    var body: some View {
        PanelRow(label: "Custom offset on \(name)", help: "Off is the standard 125 MHz.") {
            RockerSwitch(isOn: Binding(get: { custom }, set: { on in
                custom = on
                if !on {
                    entry = "125"
                    onair_antenna_converter_lo(antenna, 0)
                    changed()
                }
            }))
        }
        .onAppear {
            entry = mhz
            custom = (Double(mhz) ?? 125) != 125
        }
        if custom {
            PanelRow(label: "Frequency offset (MHz)", help: "What the converter adds to the frequency at the antenna.") {
                GlassWindow(corner: 4) {
                    TextField("125", text: $entry)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(RadioTheme.amber)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        .focused($typing)
                        .padding(6)
                        .toolbar {
                            ToolbarItemGroup(placement: .keyboard) {
                                Spacer()
                                if typing { Button("Done") { typing = false } }
                            }
                        }
                }
                .frame(width: 110, height: 32)
            }
            .onChange(of: typing) {
                guard !typing else { return }
                if let value = Double(entry), value > 0 {
                    onair_antenna_converter_lo(antenna, value)
                    changed()
                } else {
                    entry = mhz
                }
            }
        }
    }
}

/// Every mode, grouped and searchable. All 183 come from the C++ table.
struct ModeBrowser: View {
    private struct Row: Identifiable {
        let id: Int32
        let name, group, blurb: String
        let native: Bool
    }

    let receiver: Receiver
    let onPick: () -> Void
    @State private var query = ""
    @AppStorage("modesNativeOnly") private var nativeOnly = false
    private static let rows: [Row] = (0..<onair_mode_count()).map {
        let name = String(cString: onair_mode_name($0))
        return Row(id: $0, name: name, group: String(cString: onair_mode_group($0)), blurb: String(cString: onair_mode_blurb($0)),
                   native: OnAirFamily.hasNativeScreen(family: Int(onair_mode_family($0)), mode: name))
    }

    private var groups: [(String, [Row])] {
        var order: [String] = []
        var byGroup: [String: [Row]] = [:]
        for row in Self.rows where (!nativeOnly || row.native) && (query.isEmpty || row.name.localizedCaseInsensitiveContains(query) || row.blurb.localizedCaseInsensitiveContains(query)) {
            if byGroup[row.group] == nil { order.append(row.group) }
            byGroup[row.group, default: []].append(row)
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }

    var body: some View {
        ScrollViewReader { scroller in
            list
                .onAppear {
                    guard query.isEmpty, let current = Self.rows.first(where: { onair_mode_is_selected($0.id) }) else { return }
                    DispatchQueue.main.async {   // once it is laid out: the group first, since its rows do not exist until it is near
                        scroller.scrollTo(current.group, anchor: .top)
                        DispatchQueue.main.async { scroller.scrollTo(current.id, anchor: .center) }
                    }
                }
        }
    }

    private var list: some View {
        PanelPage(lazy: true) {
            GlassWindow(corner: 6) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(RadioTheme.amber)
                    TextField("", text: $query, prompt: Text("SEARCH MODES").foregroundStyle(RadioTheme.amber.opacity(0.4)))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(RadioTheme.amber)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(9)
            }
            HStack(spacing: 8) {
                HardwareKey(lit: nativeOnly, led: .green, action: { nativeOnly.toggle() }) {
                    EngravedLabel(text: "NATIVE ONLY", size: 9)
                }
                .frame(height: 46)
                Text("\(Self.rows.filter(\.native).count) of \(Self.rows.count) native")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(white: 0.08))
                    .shadow(color: .white.opacity(0.4), radius: 0, y: 0.7)
            }
            ForEach(groups, id: \.0) { group, rows in
                PanelSection(title: group) {
                    ForEach(rows) { row in
                        Button {
                            onair_mode_select(row.id)
                            receiver.refresh()
                            onPick()
                        } label: {
                            PanelRow(label: row.name, help: row.blurb) {
                                HStack(spacing: 8) {
                                    Text(row.native ? "NATIVE" : "BASIC")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(row.native ? Color.green : Color(white: 0.5))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(row.native ? Color.green.opacity(0.7) : Color(white: 0.3), lineWidth: 1))
                                    Circle()
                                        .fill(onair_mode_is_selected(row.id) ? Color.green : Color(white: 0.18))
                                        .frame(width: 10, height: 10)
                                        .shadow(color: onair_mode_is_selected(row.id) ? .green : .clear, radius: 5)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(row.id)
                    }
                }
            }
        }
    }
}
