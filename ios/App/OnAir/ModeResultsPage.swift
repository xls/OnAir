import OnAirCore
import SwiftUI

/// What the current mode is decoding, for any mode: a summary, cards and tables. Modes get richer screens of their own over time.
struct ModeResultsPage: View {
    private struct Results: Decodable {
        struct Table: Decodable {
            let name: String
            let cols: [String]
            let rows: [[String]]
        }

        var summary: String?
        var cards: [[String]]?
        var tables: [Table]?
    }

    let receiver: Receiver
    @State private var results = Results()
    @State private var tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            if !receiver.status.running {
                Text("Press play to start \(receiver.status.mode).").foregroundStyle(.secondary)
            }
            if let summary = results.summary, !summary.isEmpty {
                Section { Text(summary).font(.headline) }
            }
            if let cards = results.cards, !cards.isEmpty {
                Section {
                    ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                        LabeledContent(card.first ?? "", value: card.count > 1 ? card[1] : "")
                    }
                }
            }
            ForEach(Array((results.tables ?? []).enumerated()), id: \.offset) { _, table in
                Section(table.name) {
                    ForEach(Array(table.rows.prefix(100).enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(row.enumerated()), id: \.offset) { index, value in
                                if !value.isEmpty {
                                    LabeledContent(index < table.cols.count ? table.cols[index] : "", value: value).font(.caption)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear(perform: load)
        .onReceive(tick) { _ in load() }
    }

    private func load() {
        guard let text = onair_results_json() else { return }
        if let new = try? JSONDecoder().decode(Results.self, from: Data(String(cString: text).utf8)) { results = new }
    }
}
