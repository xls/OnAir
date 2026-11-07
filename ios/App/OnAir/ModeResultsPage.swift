import OnAirCore
import SwiftUI

/// The live numbers of a mode as a grid of readouts.
struct InstrumentGrid: View {
    let results: Results

    var body: some View {
        let cards = (results.cards ?? []).filter { $0.count == 2 && !$0[1].isEmpty }
        if !cards.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card[0]).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        Text(card[1]).font(.subheadline.monospacedDigit().weight(.medium)).lineLimit(2).minimumScaleFactor(0.7)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}

/// A mode's tables, newest rows first, with the columns as labels so they fit a phone.
struct InstrumentTables: View {
    let results: Results

    var body: some View {
        ForEach(Array((results.tables ?? []).enumerated()), id: \.offset) { _, table in
            if !table.rows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(table.name) (\(table.rows.count))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(table.rows.prefix(100).enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(row.enumerated()), id: \.offset) { index, value in
                                if !value.isEmpty {
                                    HStack(alignment: .top) {
                                        Text(index < table.cols.count ? table.cols[index] : "").foregroundStyle(.secondary)
                                        Spacer(minLength: 8)
                                        Text(value).multilineTextAlignment(.trailing)
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                        .padding(9)
                        .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }
}

/// The instrument panel of any mode: its summary, its readouts and its tables.
struct ModeResultsPage: View {
    let receiver: Receiver
    @State private var results = Results()
    @State private var tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(receiver.status.mode).font(.title3.weight(.semibold))
                    Text(receiver.status.running ? (results.summary ?? "Listening…") : "Press power to start").font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if receiver.status.running { InstrumentGrid(results: results) }   // stopped, the core still reports the TV defaults
                InstrumentTables(results: results)
            }
            .padding(12)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear(perform: load)
        .onReceive(tick) { _ in load() }
    }

    private func load() {
        if let new = Results.current() { results = new }
    }
}
