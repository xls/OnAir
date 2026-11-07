import OnAirCore
import SwiftUI

/// Mesh networks and pagers as a messaging app: conversations, the nodes heard, and sending where the mode can.
struct TexterPage: View {
    private struct Bubble: Identifiable {
        let id: Int
        let from, to, text, meta: String
    }

    private enum Section: String, CaseIterable, Identifiable {
        case messages = "Messages", nodes = "Nodes"
        var id: Self { self }
    }

    let receiver: Receiver
    @State private var results = Results()
    @State private var section = Section.messages
    @State private var showTransmit = false
    @State private var tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private static let accent = Color(red: 0.25, green: 0.8, blue: 0.65)

    private var nodes: Results.Table? { results.table(withColumn: "Hardware") ?? results.table(withColumn: "Battery %") }

    private var bubbles: [Bubble] { Self.bubbles(in: results) }

    /// What this screen would show, for the sweep.
    static func shown(_ results: Results) -> String { "bubbles=\(bubbles(in: results).count)" }

    private static func bubbles(in results: Results) -> [Bubble] {
        guard let table = results.tables?.first(where: { $0.column("Text", "Message") != nil && !$0.rows.isEmpty }) else { return [] }
        return table.rows.enumerated().map { index, row in
            Bubble(id: index, from: table.value(row, "From", "RIC", "Address", "Call"), to: table.value(row, "To", "Channel", "Protocol"),
                   text: table.value(row, "Text", "Message"), meta: table.value(row, "Time UTC", "Hops"))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(10)
            if section == .messages {
                messages
            } else {
                nodeList
            }
            if onair_tx_supported() {
                Button {
                    showTransmit = true
                } label: {
                    Label("New message", systemImage: "square.and.pencil").font(.body.weight(.semibold)).frame(maxWidth: .infinity).padding(11)
                }
                .buttonStyle(.borderedProminent)
                .tint(Self.accent)
                .padding(10)
            }
        }
        .background(Color(red: 0.05, green: 0.07, blue: 0.08).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showTransmit) { TransmitSheet(receiver: receiver) }
        .onAppear(perform: load)
        .onReceive(tick) { _ in load() }
    }

    private var messages: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if bubbles.isEmpty {
                    Text(receiver.status.running ? (results.summary ?? "Listening…") : "Press power to start").foregroundStyle(.secondary).padding()
                    if receiver.status.running { InstrumentGrid(results: results) }   // stopped, the core still reports the TV defaults
                    InstrumentTables(results: results)
                }
                ForEach(bubbles) { bubble in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(bubble.from).font(.caption.weight(.semibold)).foregroundStyle(Self.accent)
                            if !bubble.to.isEmpty { Text("→ \(bubble.to)").font(.caption2).foregroundStyle(.secondary) }
                            Spacer()
                            Text(bubble.meta).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Text(bubble.text).font(.body)
                    }
                    .padding(10)
                    .background(Color(red: 0.12, green: 0.16, blue: 0.17), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(.horizontal, 10)
        }
    }

    private var nodeList: some View {
        List(Array((nodes?.rows ?? []).enumerated()), id: \.offset) { _, row in
            if let nodes {
                VStack(alignment: .leading, spacing: 2) {
                    Text(nodes.value(row, "Name", "Id")).font(.body.weight(.medium))
                    Text([nodes.value(row, "Hardware"), nodes.value(row, "SNR dB").isEmpty ? "" : "\(nodes.value(row, "SNR dB")) dB",
                          nodes.value(row, "Battery %").isEmpty ? "" : "\(nodes.value(row, "Battery %"))%"].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
    }

    private func load() {
        if let new = Results.current() { results = new }
    }
}
