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
    case settings, scan, bearing
    var id: Self { self }
}

/// The tabs on the right edge that pull the drawers in: tap one or swipe it to the left.
struct DrawerHandle: View {
    let hasScan: Bool
    let hasBearing: Bool
    let open: (DrawerKind) -> Void

    var body: some View {
        VStack(spacing: 8) {
            if hasBearing { tab("BEARING", .bearing) }
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
                if kind == .bearing { BearingPanel() } else { OptionsDrawer(mode: mode, kind: kind) }
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

/// Which way a signal comes from, by the phase between the two antennas: a needle from straight ahead to either side.
struct BearingPanel: View {
    private struct Reading: Decodable {
        var ok = false
        var phaseDeg = 0.0
        var coherence = 0.0
        var hz = 0.0
    }

    @AppStorage("bearingSpacing") private var spacing = 0.0     // metres; 0 = half a wavelength
    @AppStorage("bearingZero") private var zero = 0.0           // the phase of a signal straight ahead
    @State private var reading = Reading()
    @State private var smooth = CGPoint.zero
    @State private var entry = ""
    @FocusState private var typing: Bool
    @State private var tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private var phase: Double { atan2(smooth.y, smooth.x) * 180 / .pi }
    private var wavelength: Double { reading.hz > 0 ? 299_792_458 / reading.hz : 0 }
    private var metres: Double { spacing > 0 ? spacing : wavelength / 2 }

    /// d sin(angle) = wavelength * phase / 360
    private var sine: Double? {
        guard reading.ok, metres > 0, reading.coherence > 0.3 else { return nil }
        var turned = (phase - zero).truncatingRemainder(dividingBy: 360)
        if turned > 180 { turned -= 360 } else if turned < -180 { turned += 360 }
        return wavelength * turned / 360 / metres
    }

    private var angle: Double? { sine.map { asin(min(max($0, -1), 1)) * 180 / .pi } }

    var body: some View {
        PanelPage {
            PanelSection(title: "Bearing") {
                Canvas { context, size in
                    let centre = CGPoint(x: size.width / 2, y: size.height - 8), radius = min(size.width / 2 - 8, size.height - 16)
                    var dial = Path()
                    dial.addArc(center: centre, radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                    context.stroke(dial, with: .color(RadioTheme.amber.opacity(0.5)), lineWidth: 1.5)
                    for mark in stride(from: -90.0, through: 90, by: 30) {
                        let r = (mark - 90) * .pi / 180
                        var tick = Path()
                        tick.move(to: CGPoint(x: centre.x + cos(r) * radius, y: centre.y + sin(r) * radius))
                        tick.addLine(to: CGPoint(x: centre.x + cos(r) * (radius - 8), y: centre.y + sin(r) * (radius - 8)))
                        context.stroke(tick, with: .color(RadioTheme.amber.opacity(0.7)), lineWidth: 1)
                    }
                    if let angle {
                        let r = (angle - 90) * .pi / 180
                        var needle = Path()
                        needle.move(to: centre)
                        needle.addLine(to: CGPoint(x: centre.x + cos(r) * (radius - 4), y: centre.y + sin(r) * (radius - 4)))
                        context.stroke(needle, with: .color(.red), lineWidth: 2.5)
                    }
                }
                .frame(height: 130)
                .padding(10)
                PanelRow(label: "Angle", help: "From straight ahead. Two antennas cannot tell in front from behind.") {
                    Text(angleText).font(.system(size: 15, design: .monospaced)).foregroundStyle(RadioTheme.amber)
                }
                PanelRow(label: "Agreement", help: "How alike the antennas hear it. Low: a reflection, two signals, or nothing there.") {
                    Text(String(format: "%.0f %%", reading.coherence * 100)).font(.system(size: 13, design: .monospaced)).foregroundStyle(RadioTheme.amber)
                }
                PanelRow(label: "Spacing (m)", help: "Between the two antennas. Half a wavelength here is \(String(format: "%.2f", wavelength / 2)) m. Blank uses that.") {
                    GlassWindow(corner: 4) {
                        TextField("auto", text: $entry)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(RadioTheme.amber)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .focused($typing)
                            .padding(6)
                    }
                    .frame(width: 84, height: 32)
                }
            }
            HardwareKey(action: { zero = phase }) { EngravedLabel(text: "THIS SIGNAL IS STRAIGHT AHEAD", size: 8) }
                .frame(height: 46)
            Text("The two receivers start at an unknown phase. Face a signal you know, tap the key, and do it again after any retune or restart.")
                .font(.footnote)
                .foregroundStyle(Color(white: 0.08))
        }
        .onAppear { entry = spacing > 0 ? String(spacing) : "" }
        .onChange(of: typing) { if !typing { spacing = Double(entry) ?? 0 } }
        .onReceive(tick) { _ in
            guard let text = onair_bearing_json(), let new = try? JSONDecoder().decode(Reading.self, from: Data(String(cString: text).utf8)) else { return }
            reading = new
            guard new.ok else { return }
            let r = new.phaseDeg * .pi / 180   // averaged as an arrow, so it can pass through 180
            smooth = CGPoint(x: smooth.x * 0.7 + cos(r) * 0.3, y: smooth.y * 0.7 + sin(r) * 0.3)
        }
    }

    private var angleText: String {
        guard reading.ok else { return "start the radio" }
        guard let angle else { return "no clear signal" }
        if (sine.map(abs) ?? 0) > 1 { return "out of range" }
        return abs(angle) < 1 ? "ahead" : String(format: "%.0f° %@", abs(angle), angle < 0 ? "left" : "right")
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
