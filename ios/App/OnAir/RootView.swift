import OnAirCore
import SwiftUI

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
    case source = "Source", gain = "Gain", tuner = "Tuner", mode = "Mode"
    var id: Self { self }
}

struct RootView: View {
    @State private var receiver = Receiver()
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
                OnAirView()
                nativePage
            }
            BottomBar(tab: $tab, modeName: receiver.status.mode)
        }
        .background(Color.black)
        .onReceive(tick) { _ in
            guard onair_is_started() else { return }
            if !started {
                started = true
                applyPage()
            }
            receiver.refresh()
        }
        .onChange(of: tab) { applyPage() }
        .onChange(of: devicePage) { applyPage() }
        .onAppear(perform: applyPage)
    }

    /// Pages that are native so far. Everything else shows the C++ panel underneath. They read from C++, so they wait until it has started,
    /// which happens once OnAirView has a size.
    @ViewBuilder private var nativePage: some View {
        if !started {
            ProgressView()
        } else if tab == .device && devicePage == .source {
            SourcePage(receiver: receiver)
        } else if tab == .device && devicePage == .mode {
            ModeBrowser(receiver: receiver) { tab = .mode }
        } else if tab == .settings {
            SettingsPage()
        }
    }

    private func applyPage() {
        switch (tab, devicePage) {
        case (.device, .gain): onair_set_page(ONAIR_PAGE_GAIN)
        case (.device, .tuner): onair_set_page(ONAIR_PAGE_TUNER)
        case (.spectrum, _): onair_set_page(ONAIR_PAGE_RECEIVER)
        case (.mode, _): onair_set_page(ONAIR_PAGE_MODE)
        default: break
        }
    }
}

/// Frequency, start and stop, and mute, on every tab.
struct StatusStrip: View {
    let receiver: Receiver
    @State private var typing = false
    @State private var typed = ""

    var body: some View {
        HStack(spacing: 12) {
            Button {
                receiver.startStop()
            } label: {
                Image(systemName: receiver.status.running ? "stop.fill" : "play.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderedProminent)
            .tint(receiver.status.running ? .red : .green)

            Button {
                typed = String(format: "%.3f", receiver.status.mhz)
                typing = true
            } label: {
                Text(String(format: "%.3f MHz", receiver.status.mhz))
                    .font(.title3.monospacedDigit().weight(.semibold))
            }
            .tint(.primary)

            Spacer()

            Button {
                receiver.setMuted(!receiver.status.muted)
            } label: {
                Image(systemName: receiver.status.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .tint(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .alert("Frequency", isPresented: $typing) {
            TextField("MHz", text: $typed).keyboardType(.decimalPad)
            Button("Tune") {
                if let mhz = Double(typed.replacingOccurrences(of: ",", with: ".")) { receiver.tune(mhz: mhz) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct ChipRow<Item: Hashable & Identifiable & RawRepresentable & CaseIterable>: View where Item.RawValue == String, Item.AllCases: RandomAccessCollection {
    @Binding var selection: Item

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Item.allCases) { item in
                    Button(item.rawValue) { selection = item }
                        .buttonStyle(.bordered)
                        .tint(item == selection ? .accentColor : .secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }
}

struct BottomBar: View {
    @Binding var tab: Tab
    let modeName: String

    private func title(_ item: Tab) -> String {
        switch item {
        case .device: "Device"
        case .spectrum: "Spectrum"
        case .mode: modeName.isEmpty ? "Mode" : modeName
        case .settings: "Settings"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.icon).font(.title3)
                        Text(title(item)).font(.caption2).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .contentShape(Rectangle())
                }
                .tint(item == tab ? .accentColor : .secondary)
            }
        }
        .padding(.top, 6)
        .background(.bar)
    }
}
