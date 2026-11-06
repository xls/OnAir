import OnAirCore
import OSLog
import SwiftUI

enum RadioKind: String, CaseIterable, Identifiable {
    case test = "Test signal", pluto = "Pluto", rtlTcp = "rtl_tcp"
    var id: Self { self }
}

/// A plain test screen: proves the receiver, its sound and the two network radios on the phone. Phase 2 replaces it.
struct ContentView: View {
    @AppStorage("radioKind") private var kind = RadioKind.pluto
    @AppStorage("host") private var host = "192.168.10.9"
    @AppStorage("rtlPort") private var rtlPort = "1234"
    @AppStorage("freqMhz") private var freqMhz = "100.0"
    @State private var running = false
    @State private var status = "stopped"
    @State private var problem = ""
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let log = Logger(subsystem: "net.rizos.onair", category: "core")

    var body: some View {
        Form {
            Picker("Source", selection: $kind) {
                ForEach(RadioKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if kind != .test {
                TextField("Address", text: $host).keyboardType(.numbersAndPunctuation).autocorrectionDisabled()
            }
            if kind == .rtlTcp {
                TextField("Port", text: $rtlPort).keyboardType(.numberPad)
            }
            LabeledContent("FM MHz") {
                TextField("MHz", text: $freqMhz).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
            Button(running ? "Stop" : "Start") { running ? stop() : start() }
            Section {
                Text(status).font(.footnote.monospaced())
                if !problem.isEmpty { Text(problem).foregroundStyle(.red) }
            }
        }
        .onAppear {
            onair_core_init(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path)
            applyLaunchArguments()
        }
        .onReceive(tick) { _ in refresh() }
    }

    private var radioSpec: String {
        switch kind {
        case .test: return ""
        case .pluto: return "pluto,\(host),0"
        case .rtlTcp: return "rtltcp,\(host),\(rtlPort)"
        }
    }

    /// `--radio <spec> --freq <MHz>` starts reception at launch, for testing from the Mac.
    private func applyLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--radio"), i + 1 < args.count else { return }
        if let f = args.firstIndex(of: "--freq"), f + 1 < args.count { freqMhz = args[f + 1] }
        start(spec: args[i + 1] == "test" ? "" : args[i + 1])
    }

    private func start(spec: String? = nil) {
        let spec = spec ?? radioSpec
        let mhz = Double(freqMhz) ?? 100
        problem = ""
        // Connecting can take seconds, and the main thread must never wait for it
        DispatchQueue.global(qos: .userInitiated).async {
            var err = [CChar](repeating: 0, count: 256)
            let ok = onair_core_start_fm(spec, mhz, &err, Int32(err.count))
            if ok { onair_core_set_volume(0.5) }
            let message = ok ? "" : String(cString: err)
            DispatchQueue.main.async { problem = message }
        }
    }

    private func stop() {
        DispatchQueue.global(qos: .userInitiated).async { onair_core_stop() }
    }

    private func refresh() {
        var line = [CChar](repeating: 0, count: 256)
        onair_core_status(&line, Int32(line.count))
        status = String(cString: line)
        running = onair_core_running()
        log.notice("\(status, privacy: .public)")
    }
}
