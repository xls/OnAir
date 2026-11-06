import OnAirCore
import OSLog
import SwiftUI

/// The first screen: proves the receiver and its sound run on the phone. Phase 2 replaces it with the real interface.
struct ContentView: View {
    @State private var running = false
    @State private var status = "stopped"
    @State private var problem = ""
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let log = Logger(subsystem: "net.rizos.onair", category: "core")

    var body: some View {
        VStack(spacing: 24) {
            Text("OnAir").font(.largeTitle.monospaced())
            Text("FM test signal: 1 kHz left, 3 kHz right").foregroundStyle(.secondary)
            Button(running ? "Stop" : "Start") { running ? stop() : start() }
                .buttonStyle(.borderedProminent)
            Text(status).font(.footnote.monospaced()).multilineTextAlignment(.center)
            if !problem.isEmpty { Text(problem).foregroundStyle(.red) }
        }
        .padding()
        .onAppear {
            onair_core_init(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path)
            if ProcessInfo.processInfo.arguments.contains("--autostart") { start() }
        }
        .onReceive(tick) { _ in refresh() }
    }

    private func start() {
        var err = [CChar](repeating: 0, count: 256)
        // Engine start can take a moment, and the main thread must never wait for it
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = onair_core_start_fm_test(&err, Int32(err.count))
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
