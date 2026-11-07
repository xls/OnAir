import OnAirCore
import SwiftUI

/// One setting of the current mode, as its desktop panel declares it (ios/host/imgui_reflect.h).
struct PanelOption: Decodable, Identifiable {
    let id: UInt32
    let kind, label, section, value, help, preview: String
    let lo, hi: Double
    let disabled: Bool
    let options: [String]
}

enum DrawerKind: String, Identifiable {
    case settings, scan
    var id: Self { self }
}

/// The tabs on the right edge that pull the drawers in: tap one or swipe it to the left.
struct DrawerHandle: View {
    let hasScan: Bool
    let open: (DrawerKind) -> Void

    var body: some View {
        VStack(spacing: 8) {
            if hasScan { tab("SCAN", .scan) }
            tab("SETTINGS", .settings)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }

    private func tab(_ title: String, _ kind: DrawerKind) -> some View {
        HStack(spacing: 3) {
            Capsule().fill(Color.white.opacity(0.55)).frame(width: 3, height: 26)
            Text(title)
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(white: 0.08))
                .fixedSize()
                .rotationEffect(.degrees(-90))
                .frame(width: 9, height: title.count > 4 ? 56 : 30)
        }
        .padding(.leading, 3)
        .padding(.trailing, 2)
        .padding(.vertical, 8)
        .background(BrushedMetal(tone: 0.52).clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8)))
        .shadow(color: .black.opacity(0.5), radius: 3, x: -1)
        .contentShape(Rectangle())
        .onTapGesture { open(kind) }
        .gesture(DragGesture(minimumDistance: 6).onEnded { if $0.translation.width < 0 { open(kind) } })
        .accessibilityLabel(title == "SETTINGS" ? "Settings for this mode" : title.capitalized)
        .accessibilityAddTraits(.isButton)
    }
}

/// A drawer that slides in from the right over the page. The top bar and the bottom keys stay in view, and so does a strip of the page.
struct SideDrawer: View {
    let mode: String
    let kind: DrawerKind
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.3).contentShape(Rectangle()).onTapGesture(perform: close).transition(.opacity)
            HStack(spacing: 0) {
                Capsule().fill(Color.white.opacity(0.5)).frame(width: 4, height: 44).padding(.horizontal, 4)
                OptionsDrawer(mode: mode, kind: kind)
            }
            .background(BrushedMetal(tone: 0.46))
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12))
            .shadow(color: .black.opacity(0.6), radius: 8, x: -3)
            .padding(.leading, 40)
            .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { value in
                if value.translation.width > 70, abs(value.translation.width) > abs(value.translation.height) { close() }
            })
            .transition(.move(edge: .trailing))
        }
    }
}

/// Every setting of the current mode, in native controls.
struct OptionsDrawer: View {
    let mode: String
    var kind = DrawerKind.settings
    @State private var all: [PanelOption] = []
    @State private var query = ""
    @State private var text = ""
    @State private var tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private var shown: [PanelOption] {
        all.filter { $0.section.hasPrefix("Scan") == (kind == .scan) && !$0.label.isEmpty && (query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) || $0.help.localizedCaseInsensitiveContains(query) || $0.section.localizedCaseInsensitiveContains(query)) }
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
                    TextField("", text: $query, prompt: Text(kind == .scan ? "SEARCH SCAN" : "SEARCH \(mode.uppercased())").foregroundStyle(RadioTheme.amber.opacity(0.4)))
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
                case .single(let option):
                    if option.kind == "pick" {
                        // a scan result: its frequency, the name beside it, the rest under them
                        let columns = option.help.components(separatedBy: " · ")
                        Button { onair_option_set(option.id, "1") } label: {
                            StationRow(frequency: option.label, name: columns.first ?? "", note: columns.dropFirst().joined(separator: " · "))
                        }
                        .buttonStyle(.plain)
                    } else if option.kind == "note" {
                        Text(option.label)
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(RadioTheme.amber.opacity(0.75))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                    } else {
                        OptionRow(option: option)
                    }
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
                    if option.options.allSatisfy(\.isEmpty) {
                        Text(option.preview).font(.system(size: 12, design: .monospaced)).foregroundStyle(RadioTheme.amber.opacity(0.6))
                    } else {
                        SelectorWindow(selected: selected, options: option.options) { onair_option_set(option.id, String($0)) }
                    }
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
        guard let index = Int(option.value), option.options.indices.contains(index) else { return option.preview.isEmpty ? "Choose" : option.preview }
        return option.options[index]
    }

    private var valueText: String {
        let value = draft ?? Double(option.value) ?? 0
        return value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }
}

/// A test: changes each setting of the current mode, checks that the panel took it, and puts it back. Writes Documents/effects.json.
enum OptionSweep {
    private struct Result: Encodable {
        let label, kind, section, from, to, after: String
        let took: Bool
    }

    private static func read() -> [PanelOption] {
        guard let json = onair_options_json() else { return [] }
        return (try? JSONDecoder().decode([PanelOption].self, from: Data(String(cString: json).utf8))) ?? []
    }

    private static func changed(_ option: PanelOption) -> String? {
        switch option.kind {
        case "toggle": return option.value == "1" ? "0" : "1"
        case "choice":
            let usable = option.options.indices.filter { !option.options[$0].isEmpty && String($0) != option.value }
            return usable.first.map(String.init)
        case "slider":
            let value = Double(option.value) ?? option.lo
            return String(value > (option.lo + option.hi) / 2 ? option.lo + (option.hi - option.lo) * 0.25 : option.lo + (option.hi - option.lo) * 0.75)
        case "number": return String((Double(option.value) ?? 0) + 1)
        default: return nil
        }
    }

    @MainActor static func run() async {
        onair_options_watch(true)
        try? await Task.sleep(for: .seconds(3))
        var out: [Result] = []
        let unsafe = ["transmit", "send", "record", "delete", "clear", "tx "]
        let options = read().filter { option in !unsafe.contains { option.label.lowercased().contains($0) } }
        for option in options.prefix(45) {
            guard let value = changed(option) else { continue }
            onair_option_set(option.id, value)
            try? await Task.sleep(for: .milliseconds(450))
            let now = read().first { $0.id == option.id }
            let took = now.map { (Double($0.value) ?? .nan) == (Double(value) ?? .infinity) || $0.value == value || $0.value != option.value } ?? false
            out.append(Result(label: option.label, kind: option.kind, section: option.section, from: option.value, to: value, after: now?.value ?? "gone", took: took))
            onair_option_set(option.id, option.value)
            try? await Task.sleep(for: .milliseconds(300))
        }
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("effects.json")
        try? JSONEncoder().encode(out).write(to: file)
    }
}

/// One found station, in the same order everywhere: the frequency, then the name, full size.
struct StationRow: View {
    let frequency, name, note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                Text(frequency).font(.system(size: 15, weight: .medium, design: .monospaced)).monospacedDigit()
                Text(name).font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(RadioTheme.amber)
            if !note.isEmpty {
                Text(note).font(.system(size: 10, design: .rounded)).foregroundStyle(RadioTheme.amber.opacity(0.55)).lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
    }
}
