import OnAirCore
import SwiftUI

enum OnAirFamily {
    static let fm = 5
}

enum Tab: CaseIterable, Identifiable {
    case device, spectrum, mode, settings
    var id: Self { self }

    var icon: String {
        switch self {
        case .device: "antenna.radiowaves.left.and.right"
        case .spectrum: "waveform.path.ecg"
        case .mode: "dot.radiowaves.up.forward"
        case .settings: "gearshape"
        }
    }
}

enum DevicePage: String, CaseIterable, Identifiable {
    case source = "Source", gain = "Gain", radio = "Radio", mode = "Mode", display = "Display"
    var id: Self { self }
}

struct RootView: View {
    @State private var receiver = Receiver()
    @State private var spectrum = SpectrumRenderer()
    @State private var tab = Tab.device
    @State private var devicePage = DevicePage.source
    @State private var started = false
    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            StatusStrip(receiver: receiver)
            if tab == .device {
                ChipRow(selection: $devicePage)
            }
            ZStack {
                OnAirView().opacity(0).allowsHitTesting(false)
                Color.black
                nativePage
            }
            BottomBar(tab: $tab, modeName: receiver.status.mode)
        }
        .background(BrushedMetal(tone: 0.46).ignoresSafeArea())
        .onReceive(tick) { _ in
            guard onair_is_started() else { return }
            if !started {
                started = true
                onair_set_page(ONAIR_PAGE_NONE)
                if ProcessInfo.processInfo.arguments.contains("--start") { receiver.startStop() }
            }
            receiver.refresh()
        }
        .onAppear {
            TiltLight.shared.start()
            openLaunchPage()
        }
    }

    /// Every page is native. They read from C++, so they wait until it has started,
    /// which happens once OnAirView has a size.
    @ViewBuilder private var nativePage: some View {
        if !started {
            ProgressView()
        } else if tab == .device && devicePage == .source {
            SourcePage(receiver: receiver)
        } else if tab == .device && devicePage == .gain {
            GainPage()
        } else if tab == .device && devicePage == .radio {
            RadioSettingsPage()
        } else if tab == .device && devicePage == .mode {
            ModeBrowser(receiver: receiver) { tab = .mode }
        } else if tab == .device && devicePage == .display {
            SettingsPage(only: "Spectrum and waterfall")
        } else if tab == .spectrum {
            SpectrumPage(receiver: receiver, spectrum: spectrum)
        } else if tab == .mode {
            if receiver.status.family == OnAirFamily.fm {
                FMRadioPage(receiver: receiver)
            } else {
                ModeResultsPage(receiver: receiver)
            }
        } else if tab == .settings {
            SettingsPage(only: nil)
        }
    }

    /// `--page settings`, `--page gain` and so on open a page at launch, for checking screens from the Mac.
    private func openLaunchPage() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--page"), i + 1 < args.count else { return }
        switch args[i + 1] {
        case "settings": tab = .settings
        case "fm":
            tab = .mode
        case "spectrum": tab = .spectrum
        case "mode": tab = .mode
        default: devicePage = DevicePage.allCases.first { $0.rawValue.lowercased() == args[i + 1] } ?? .source
        }
    }
}

/// The top of the unit: power, a lit frequency window and the mute key.
struct StatusStrip: View {
    let receiver: Receiver
    @State private var typing = false
    @State private var typed = ""

    var body: some View {
        ZStack {
            BrushedMetal(tone: 0.46)
            HStack(spacing: 10) {
                HardwareKey(lit: receiver.status.running, led: .green, action: receiver.startStop) {
                    EngravedLabel(text: receiver.status.running ? "STOP" : "POWER", size: 8)
                }
                .frame(width: 62)

                Button {
                    typed = String(format: "%.5f", receiver.status.mhz)
                    typing = true
                } label: {
                    GlassWindow(corner: 6) {
                        Text(String(format: "%.5f MHz", receiver.status.mhz))
                            .font(.system(size: 19, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(RadioTheme.amber)
                            .shadow(color: RadioTheme.amber.opacity(0.8), radius: 6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .buttonStyle(.plain)

                HardwareKey(lit: receiver.status.muted, led: .red, action: { receiver.setMuted(!receiver.status.muted) }) {
                    EngravedLabel(text: "MUTE", size: 8)
                }
                .frame(width: 62)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .frame(height: 58)
        .alert("Frequency", isPresented: $typing) {
            TextField("MHz", text: $typed).keyboardType(.decimalPad)
            Button("Tune") {
                if let mhz = Double(typed.replacingOccurrences(of: ",", with: ".")) { receiver.tune(mhz: mhz) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// A row of machined keys.
struct ChipRow<Item: Hashable & Identifiable & RawRepresentable & CaseIterable>: View where Item.RawValue == String, Item.AllCases: RandomAccessCollection {
    @Binding var selection: Item

    var body: some View {
        ZStack {
            BrushedMetal(tone: 0.46)
            HStack(spacing: 5) {
                ForEach(Item.allCases) { item in
                    HardwareKey(lit: item == selection, action: { selection = item }) {
                        EngravedLabel(text: item.rawValue.uppercased(), size: 8)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(height: 54)
    }
}

/// The keys along the bottom of the unit.
struct BottomBar: View {
    @Binding var tab: Tab
    let modeName: String

    private func title(_ item: Tab) -> String {
        switch item {
        case .device: "DEVICE"
        case .spectrum: "SPECTRUM"
        case .mode: modeName.isEmpty ? "MODE" : modeName.uppercased()
        case .settings: "SETTINGS"
        }
    }

    var body: some View {
        ZStack {
            BrushedMetal(tone: 0.46)
            HStack(spacing: 7) {
                ForEach(Tab.allCases) { item in
                    HardwareKey(lit: item == tab, led: RadioTheme.teal, action: { tab = item }) {
                        VStack(spacing: 2) {
                            Image(systemName: item.icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(white: 0.1))
                            EngravedLabel(text: title(item), size: 7).lineLimit(1).minimumScaleFactor(0.6)
                        }
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.top, 7)
            .padding(.bottom, 4)
        }
        .frame(height: 72)
    }
}
