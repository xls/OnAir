import OnAirCore
import SwiftUI

/// One setting of the current mode, as its desktop panel declares it (ios/host/imgui_reflect.h).
struct PanelOption: Decodable, Identifiable {
    let id: UInt32
    let kind, label, section, value, help: String
    let lo, hi: Double
    let disabled: Bool
    let options: [String]
}

/// The tab that pulls the settings drawer up: tap it or swipe it.
struct DrawerHandle: View {
    let open: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            Capsule().fill(Color.white.opacity(0.55)).frame(width: 34, height: 3)
            EngravedLabel(text: "SETTINGS", size: 7)
        }
        .padding(.horizontal, 16)
        .padding(.top, 5)
        .padding(.bottom, 3)
        .background(BrushedMetal(tone: 0.52).clipShape(UnevenRoundedRectangle(topLeadingRadius: 9, topTrailingRadius: 9)))
        .shadow(color: .black.opacity(0.5), radius: 3, y: -1)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .gesture(DragGesture(minimumDistance: 8).onEnded { if $0.translation.height < 0 { open() } })
        .frame(maxHeight: .infinity, alignment: .bottom)
        .accessibilityLabel("Settings for this mode")
        .accessibilityAddTraits(.isButton)
    }
}

/// Every setting of the current mode, in native controls. It rises halfway so the page stays in view while you change things.
struct OptionsDrawer: View {
    let mode: String
    @State private var all: [PanelOption] = []
    @State private var query = ""
    @State private var text = ""
    @State private var tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private var shown: [PanelOption] {
        all.filter { !$0.label.isEmpty && (query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) || $0.help.localizedCaseInsensitiveContains(query) || $0.section.localizedCaseInsensitiveContains(query)) }
    }

    private var sections: [(String, [PanelOption])] {
        var order: [String] = []
        var byName: [String: [PanelOption]] = [:]
        for option in shown {
            if byName[option.section] == nil { order.append(option.section) }
            byName[option.section, default: []].append(option)
        }
        return order.map { ($0, byName[$0] ?? []) }
    }

    var body: some View {
        PanelPage {
            GlassWindow(corner: 6) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(RadioTheme.amber)
                    TextField("", text: $query, prompt: Text("SEARCH \(mode.uppercased())").foregroundStyle(RadioTheme.amber.opacity(0.4)))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(RadioTheme.amber)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(9)
            }
            if shown.isEmpty {
                Text(all.isEmpty ? "This mode has no settings of its own." : "Nothing matches.")
                    .font(.footnote)
                    .foregroundStyle(Color(white: 0.08))
            }
            ForEach(sections, id: \.0) { title, options in
                OptionSection(title: title, options: options)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationDragIndicator(.visible)
        .onAppear {
            onair_options_watch(true)
            load()
        }
        .onDisappear { onair_options_watch(false) }
        .onReceive(tick) { _ in load() }
    }

    private func load() {
        guard let json = onair_options_json() else { return }
        let new = String(cString: json)
        guard new != text else { return }
        text = new
        if let list = try? JSONDecoder().decode([PanelOption].self, from: Data(new.utf8)) { all = list }
    }
}

private struct OptionSection: View {
    let title: String
    let options: [PanelOption]

    /// Radio buttons side by side are one choice, and buttons go last, as a block of keys.
    private enum Part: Identifiable {
        case single(PanelOption)
        case radios([PanelOption])
        var id: UInt32 {
            switch self {
            case .single(let option): option.id
            case .radios(let group): group[0].id
            }
        }
    }

    private var parts: [Part] {
        var out: [Part] = []
        var run: [PanelOption] = []
        func flush() { if !run.isEmpty { out.append(.radios(run)); run = [] } }
        for option in options where option.kind != "button" {
            if option.kind == "radio" { run.append(option) } else { flush(); out.append(.single(option)) }
        }
        flush()
        return out
    }

    private var keys: [PanelOption] { options.filter { $0.kind == "button" } }
    private static let grid = [GridItem(.adaptive(minimum: 96), spacing: 6)]

    var body: some View {
        PanelSection(title: title.isEmpty ? "Options" : title) {
            ForEach(parts) { part in
                switch part {
                case .single(let option): OptionRow(option: option)
                case .radios(let group): radios(group)
                }
            }
            if !keys.isEmpty {
                LazyVGrid(columns: Self.grid, spacing: 6) {
                    ForEach(keys) { key in
                        HardwareKey(action: { onair_option_set(key.id, "1") }) {
                            EngravedLabel(text: key.label.uppercased(), size: 8)
                        }
                        .frame(height: 38)
                        .disabled(key.disabled)
                        .opacity(key.disabled ? 0.5 : 1)
                    }
                }
                .padding(10)
            }
        }
    }

    private func radios(_ group: [PanelOption]) -> some View {
        LazyVGrid(columns: Self.grid, spacing: 6) {
            ForEach(group) { option in
                HardwareKey(lit: option.value == "1", led: .green, action: { onair_option_set(option.id, "1") }) {
                    EngravedLabel(text: option.label.uppercased(), size: 8)
                }
                .frame(height: 38)
                .disabled(option.disabled)
            }
        }
        .padding(10)
    }
}

private struct OptionRow: View {
    let option: PanelOption
    @State private var draft: Double?
    @State private var entry = ""
    @FocusState private var typing: Bool

    var body: some View {
        Group {
            switch option.kind {
            case "toggle":
                PanelRow(label: option.label, help: option.help) {
                    RockerSwitch(isOn: Binding(get: { option.value == "1" }, set: { onair_option_set(option.id, $0 ? "1" : "0") }))
                }
            case "choice":
                PanelRow(label: option.label, help: option.help) {
                    SelectorWindow(selected: selected, options: option.options) { onair_option_set(option.id, String($0)) }
                }
            case "slider":
                VStack(spacing: 0) {
                    PanelRow(label: option.label, help: option.help) {
                        Text(valueText).font(.system(size: 13, design: .monospaced)).foregroundStyle(RadioTheme.amber)
                    }
                    Fader(value: Binding(get: { draft ?? Double(option.value) ?? option.lo }, set: { draft = $0; onair_option_set(option.id, String($0)) }),
                          range: option.lo...max(option.hi, option.lo + 1e-6)) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { draft = nil }
                    }
                    .frame(height: 40)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                }
            default:
                PanelRow(label: option.label, help: option.help) {
                    GlassWindow(corner: 4) {
                        TextField("", text: $entry)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(RadioTheme.amber)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(option.kind == "number" ? .decimalPad : .default)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($typing)
                            .padding(6)
                    }
                    .frame(width: 130, height: 32)
                }
            }
        }
        .disabled(option.disabled)
        .opacity(option.disabled ? 0.5 : 1)
        .onAppear { entry = option.value }
        .onChange(of: option.value) { if !typing { entry = option.value } }
        .onChange(of: typing) { if !typing, entry != option.value { onair_option_set(option.id, entry) } }
    }

    private var selected: String {
        guard let index = Int(option.value), option.options.indices.contains(index) else { return "Choose" }
        return option.options[index]
    }

    private var valueText: String {
        let value = draft ?? Double(option.value) ?? 0
        return value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }
}
