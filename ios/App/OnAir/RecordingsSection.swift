import OnAirCore
import SwiftUI
import UniformTypeIdentifiers

/// IQ recordings: record the radio, bring files in, and play one back through whichever mode it was made in.
struct RecordingsSection: View {
    struct Recording: Decodable, Identifiable {
        var name: String
        var path: String
        var rate: Double
        var hz: Double
        var seconds: Double
        var mode: String
        var id: String { path }
    }

    private struct Stats: Decodable {
        var active = false
        var seconds = 0.0
        var bytes = 0.0
        var dropped = 0.0
        var error = ""
    }

    let receiver: Receiver
    @State private var recordings: [Recording] = []
    @State private var stats = Stats()
    @State private var importing = false
    @State private var rawFile: Recording?
    @State private var rateText = "2"
    @State private var message = ""
    @State private var tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 10) {
            HardwareKey(action: toggleRecording) {
                EngravedLabel(text: stats.active ? String(format: "STOP %.0f S", stats.seconds) : "RECORD", size: 9)
            }
            HardwareKey(action: { importing = true }) {
                EngravedLabel(text: "IMPORT", size: 9)
            }
        }
        .frame(height: 50)
        PanelSection(title: "Recordings") {
            if !message.isEmpty { PanelRow(label: message) { EmptyView() } }
            ForEach(recordings) { recording in
                Button { play(recording) } label: {
                    PanelRow(label: URL(fileURLWithPath: recording.name).deletingPathExtension().lastPathComponent) {
                        Text(detail(recording)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(recording) }
                }
            }
            if recordings.isEmpty { PanelRow(label: "None yet") { EmptyView() } }
        }
        .onAppear(perform: load)
        .onReceive(tick) { _ in load() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true, onCompletion: bringIn)
        .alert("Sample rate in MHz", isPresented: Binding(get: { rawFile != nil }, set: { if !$0 { rawFile = nil } })) {
            TextField("MHz", text: $rateText).keyboardType(.decimalPad)
            Button("Play") { if let rawFile { open(rawFile, rate: (Double(rateText) ?? 0) * 1e6) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This file does not say how fast it was recorded.")
        }
    }

    private func detail(_ recording: Recording) -> String {
        var parts: [String] = []
        if recording.hz > 0 { parts.append(String(format: "%.3f MHz", recording.hz / 1e6)) }
        if recording.seconds > 0 { parts.append(String(format: "%.0f s", recording.seconds)) }
        return parts.joined(separator: " · ")
    }

    private func load() {
        if let text = onair_iq_list_json(), let list = try? JSONDecoder().decode([Recording].self, from: Data(String(cString: text).utf8)) { recordings = list }
        if let text = onair_iq_record_json(), let new = try? JSONDecoder().decode(Stats.self, from: Data(String(cString: text).utf8)) {
            if !new.error.isEmpty { message = new.error }
            stats = new
        }
    }

    private func toggleRecording() {
        let on = !stats.active
        if on && !receiver.status.running { message = "Start the radio first"; return }
        message = onair_iq_record(on) ? "" : "Could not record from this source"
        load()
    }

    private func play(_ recording: Recording) {
        if recording.rate > 0 { open(recording, rate: recording.rate) } else { rawFile = recording }
    }

    private func open(_ recording: Recording, rate: Double) {
        message = onair_iq_open(recording.path, rate) ? "" : "Could not play \(recording.name)"
        receiver.refresh()
    }

    private func delete(_ recording: Recording) {
        // the samples, the SigMF data beside them and the description all share the name
        let url = URL(fileURLWithPath: recording.path)
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent == stem {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        load()
    }

    /// A copy: a picked file can only be read by itself, and a SigMF recording is two files side by side.
    private func bringIn(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        let folder = URL(fileURLWithPath: String(cString: onair_iq_folder()))
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent)) }
            catch { message = "Could not copy \(url.lastPathComponent)" }
        }
        load()
    }
}
