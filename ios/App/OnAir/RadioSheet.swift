import OnAirCore
import SwiftUI

/// Adds a network radio. The native form sets what the desktop's Network radios window sets, and C++ does the rest.
struct RadioSheet: View {
    /// The raw values are OnAir's NetRadio::Type. SoapyRemote needs SoapySDR, which this app does not have.
    private enum Kind: Int, CaseIterable, Identifiable {
        case pluto = 0, rtlTcp = 1, spyServer = 3, hermesLite = 4, redPitaya = 5, sdrpp = 6, nrsp = 7, kiwi = 8, tci = 10
        var id: Self { self }

        var label: String {
            switch self {
            case .pluto: "Pluto (by IP)"
            case .rtlTcp: "rtl_tcp"
            case .spyServer: "SpyServer"
            case .hermesLite: "Hermes Lite 2"
            case .redPitaya: "Red Pitaya"
            case .sdrpp: "SDR++ server"
            case .nrsp: "SDRplay nRSP-ST"
            case .kiwi: "KiwiSDR"
            case .tci: "TCI"
            }
        }

        var help: String {
            switch self {
            case .pluto: "Any Pluto-compatible radio: the E310, Pluto+, or a stock Pluto on a network."
            case .rtlTcp: "An RTL-SDR served by rtl_tcp on another computer."
            case .sdrpp: "SDR++ running with --server. It takes one client at a time."
            case .nrsp: "Reached through SDRconnect's WebSocket server."
            case .kiwi: "A receiver on the internet, 0 to 30 MHz."
            case .tci: "ExpertSDR3 and others with a TCI server. Receive only."
            default: ""
            }
        }

        /// A radio here can be a name as well as a number, so the full keyboard is needed; a Pluto or rtl_tcp address is a number.
        var numericAddress: Bool { self == .pluto || self == .rtlTcp || self == .hermesLite || self == .redPitaya }

        var defaultPort: String {
            switch self {
            case .pluto: "0"
            case .rtlTcp: "1234"
            case .spyServer: "5555"
            case .hermesLite: "1024"
            case .redPitaya: "1024"
            case .sdrpp: "5259"
            case .nrsp: "5454"
            case .kiwi: "8073"
            case .tci: "50001"
            }
        }
    }

    @AppStorage("radioKind") private var kind = Kind.pluto
    @AppStorage("radioHost") private var host = "192.168.10.9"
    @AppStorage("radioPort") private var port = "0"
    @State private var password = ""
    @State private var busy = false
    @State private var problem = ""
    @Environment(\.dismiss) private var dismiss
    @State private var poll = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        PanelPage {
            PanelSection(title: "Network radio") {
                PanelRow(label: "Type", help: kind.help) {
                    SelectorWindow(selected: kind.label, options: Kind.allCases.map(\.label)) { index in
                        kind = Kind.allCases[index]
                        port = kind.defaultPort
                    }
                }
                PanelRow(label: "Address") {
                    GlassWindow(corner: 4) {
                        TextField("", text: $host)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(RadioTheme.amber)
                            .keyboardType(kind.numericAddress ? .decimalPad : .URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .padding(8)
                            .frame(width: 170)
                    }
                }
                if kind != .pluto {
                    PanelRow(label: "Port") {
                        GlassWindow(corner: 4) {
                            TextField("", text: $port)
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundStyle(RadioTheme.amber)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .padding(8)
                                .frame(width: 90)
                        }
                    }
                }
            }
            if kind == .kiwi {
                PanelSection(title: "Access") {
                    PanelRow(label: "Password", help: "Leave empty for a public receiver.") {
                        GlassWindow(corner: 4) {
                            SecureField("", text: $password)
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundStyle(RadioTheme.amber)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                                .padding(8)
                                .frame(width: 170)
                        }
                    }
                }
            }
            if !problem.isEmpty {
                Text(problem).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                HardwareKey(action: { dismiss() }) { EngravedLabel(text: "CANCEL", size: 9) }
                HardwareKey(lit: busy, led: .green, action: connect) { EngravedLabel(text: busy ? "CONNECTING" : "CONNECT", size: 9) }
            }
            .frame(height: 54)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onReceive(poll) { _ in check() }
    }

    private func connect() {
        guard !busy, !host.isEmpty else { return }
        problem = ""
        busy = true
        onair_net_password(password)
        onair_net_connect(Int32(kind.rawValue), host, Int32(port) ?? 0)
    }

    private func check() {
        guard busy, !onair_net_busy() else { return }
        busy = false
        problem = String(cString: onair_net_error())
        if problem.isEmpty { dismiss() }
    }
}
