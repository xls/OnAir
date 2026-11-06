import OnAirCore
import SwiftUI

enum OnAirFamily {
    static let fm = 5
    /// DVB-T/T2, ATSC, ATSC 3.0, ISDB-T, DVB-S/S2, DTMB, DVB-C
    static let television: Set<Int> = [0, 1, 3, 4, 6, 7, 40, internetTV]
    static let internetTV = 209
}

extension OnAirFamily {
    /// HF digital, CW, PSK, JS8Call and friends, and the general receiver for voice.
    static let hamFamilies: Set<Int> = [25, 34, 36, 37, 95, 113, 116, 119, 140, 205]
    /// DAB, DRM, HD Radio, AM, AM stereo, CDR, shortwave
    static let broadcast: Set<Int> = [2, 10, 21, 55, 107, 22]
    /// ADS-B, GNSS, sondes, AIS, UAT, FLARM, drones, VDES, APRS, Orbcomm, SARSAT, ASTERIX, Argos, LoRa satellites
    static let trackers: Set<Int> = [11, 12, 13, 14, 83, 66, 56, 68, 63, 24, 44, 92, 151, 152, 201]
    /// DMR, NXDN, P25, dPMR, TETRA, TETRAPOL, trunking, D-STAR, M17, Fusion
    static let twoWay: Set<Int> = [9, 38, 50, 180, 45, 46, 79, 127, 129, 130, 33, 31, 128]
    /// LoRa mesh networks, pagers, aircraft data links, marine text and satellite messages
    static let messaging: Set<Int> = [20, 23, 75, 15, 16, 17, 18, 27, 35, 82, 76, 81, 146, 147, 204, 141]
    /// Weather satellites and anything else that decodes pictures
    static let pictures: Set<Int> = [59, 60, 64, 80, 206, 230, 231, 232, 233, 234, 235, 236, 53, 131, 212]
    /// Sensors, networks and cells
    static let devices: Set<Int> = [28, 32, 39, 51, 54, 57, 65, 69, 70, 77, 78, 84, 86, 98, 71, 143, 148, 153, 200, 210]

    static func isHam(family: Int, mode: String) -> Bool { hamFamilies.contains(family) || mode == "General receiver" }

    /// True when the mode opens a screen of its own rather than the generic results list. RootView's page choice follows the same sets.
    static func hasNativeScreen(family: Int, mode: String) -> Bool {
        family == fm || television.contains(family) || isHam(family: family, mode: mode) || broadcast.contains(family) || trackers.contains(family) ||
            twoWay.contains(family) || messaging.contains(family) || pictures.contains(family) || devices.contains(family)
    }
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
    @State private var autoSelected = false
    @State private var tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            if !receiver.videoFullscreen {
                StatusStrip(receiver: receiver)
                if tab == .device {
                    ChipRow(selection: $devicePage)
                }
            }
            ZStack {
                OnAirView().opacity(0).allowsHitTesting(false)
                Color.black
                nativePage
            }
            if !receiver.videoFullscreen {
                BottomBar(tab: $tab, modeName: receiver.status.mode)
            }
        }
        .background(BrushedMetal(tone: 0.46).ignoresSafeArea())
        .statusBarHidden(receiver.videoFullscreen)
        .persistentSystemOverlays(receiver.videoFullscreen ? .hidden : .automatic)
        .onReceive(tick) { _ in
            guard onair_is_started() else { return }
            if !started {
                started = true
                onair_set_page(ONAIR_PAGE_NONE)
                applyTestArguments()
            }
            receiver.refresh()
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true   // a radio stays on: the screen does not lock by itself while the app is open
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
            } else if OnAirFamily.television.contains(receiver.status.family) {
                TVPage(receiver: receiver)
            } else if OnAirFamily.isHam(family: receiver.status.family, mode: receiver.status.mode) {
                HamPage(receiver: receiver, spectrum: spectrum)
            } else if OnAirFamily.broadcast.contains(receiver.status.family) {
                BroadcastPage(receiver: receiver)
            } else if OnAirFamily.trackers.contains(receiver.status.family) {
                TrackerPage(receiver: receiver)
            } else if OnAirFamily.twoWay.contains(receiver.status.family) {
                TwoWayPage(receiver: receiver)
            } else if OnAirFamily.messaging.contains(receiver.status.family) {
                TexterPage(receiver: receiver)
            } else if OnAirFamily.pictures.contains(receiver.status.family) {
                PicturePage(receiver: receiver)
            } else if OnAirFamily.devices.contains(receiver.status.family) {
                DevicesPage(receiver: receiver)
            } else {
                ModeResultsPage(receiver: receiver)
            }
        } else if tab == .settings {
            SettingsPage(only: nil)
        }
    }

    /// `--mode <name> --source test --start` pick what to run at launch; the status then goes to the log. Used by tools/verify_mode.sh.
    private func applyTestArguments() {
        let args = ProcessInfo.processInfo.arguments
        func value(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let source = value("--source") { onair_source_select_named(source) }  // first: the automatic modes start listening when selected
        if let mode = value("--mode") { _ = onair_mode_select_named(mode) }
        var label = value("--mode") ?? ""
        if let index = value("--mode-index").flatMap(Int32.init), index < onair_mode_count() {
            onair_mode_select(index)
            label = String(cString: onair_mode_name(index))
            NSLog("OnAirVerify index %d of %d is %@ family %d group %@", index, onair_mode_count(), label, onair_mode_family(index), String(cString: onair_mode_group(index)))
        }
        if let bandwidth = value("--bw"), let mhz = Double(bandwidth) { onair_tv_bandwidth(mhz) }
        if let gain = value("--gain"), let db = Double(gain) { onair_gain_set(db) }
        if let frequency = value("--freq"), let mhz = Double(frequency) { onair_tune_mhz(mhz) }
        if args.contains("--start") && !onair_running() { receiver.startStop() }  // the automatic modes start themselves
        if let address = value("--iptv") { onair_iptv_open(address) }
        if let channel = value("--iptv-channel").flatMap(Int32.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { onair_iptv_play(channel) }
        }
        if let file = value("--ts") { onair_tv_play_file(file) }
        if let path = value("--tx-file") { transmitToFile(path, mode: value("--mode") ?? "") }
        if !label.isEmpty {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated {
                    NSLog("OnAirVerify%@", String(cString: onair_verify_line()))
                    NSLog("OnAirVerify auto %@ iptv %@", String(cString: onair_auto_message()), String(cString: onair_iptv_json()))
                    if let shown = Results.current() {
                        NSLog("OnAirVerify shown cards=%d tables=%d rows=%d summary=%@", shown.cards?.count ?? 0, shown.tables?.count ?? 0, shown.tables?.reduce(0) { $0 + $1.rows.count } ?? 0, shown.summary ?? "")
                    } else {
                        NSLog("OnAirVerify shown failed to decode")
                    }
                    if onair_tv_first_service() >= 0 { onair_tv_play(onair_tv_first_service()) }
                    if !autoSelected, let table = Results.current()?.table("Services"), let first = table.rows.first(where: { !table.value($0, "Subch").isEmpty }) {
                        autoSelected = true
                        onair_broadcast_select(Int32(table.value(first, "Subch")) ?? -1)
                    }
                }
            }
        }
    }

    /// Runs the transmit chain into an IQ file, so nothing goes on air: used to check a mode's transmitter from the Mac.
    private func transmitToFile(_ path: String, mode: String) {
        var err = [CChar](repeating: 0, count: 256)
        let ok = "VK2TST".withCString { call in
            "QF56".withCString { grid in
                path.withCString { file in
                    var request = OnAirTxRequest(mhz: receiver.status.mhz, gainDb: -30, seconds: 3, callsign: call, grid: grid, text: nil, dest: nil, kind: 0, wpm: 20, microphone: false, iqPath: file)
                    return onair_tx_start(&request, &err, Int32(err.count))
                }
            }
        }
        NSLog("OnAirVerify txfile %@ ok=%d %@", mode, ok ? 1 : 0, String(cString: err))
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
    @State private var showDrawer = false

    var body: some View {
        ZStack {
            BrushedMetal(tone: 0.46)
            HStack(spacing: 10) {
                HardwareKey(lit: receiver.status.running, led: .green, action: receiver.startStop) {
                    EngravedLabel(text: receiver.status.running ? "STOP" : "POWER", size: 8)
                }
                .frame(width: 62)

                Button {
                    showDrawer = true
                } label: {
                    GlassWindow(corner: 6) {
                        Text(String(format: "%.3f MHz", receiver.status.mhz))
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
        .sheet(isPresented: $showDrawer) {
            FrequencyDrawer(receiver: receiver)
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
