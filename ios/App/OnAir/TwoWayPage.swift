import OnAirCore
import SwiftUI

/// Two-way radio, laid out like a dispatcher's console: who is talking now, then the calls and talkgroups heard.
struct TwoWayPage: View {
    let receiver: Receiver
    @State private var results = Results()
    @State private var tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    private static let surface = Color(red: 0.07, green: 0.09, blue: 0.1)
    private static let accent = Color(red: 0.2, green: 0.9, blue: 0.6)

    private var calls: Results.Table? { results.tables?.first { $0.column("Source", "MY") != nil } }
    private var talkgroups: Results.Table? { results.table(withColumn: "Talkgroup") }
    private var latest: [String]? { calls?.rows.last }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                active
                stats
                if let talkgroups, !talkgroups.rows.isEmpty { section("Talkgroups", talkgroups) { row in talkgroupRow(talkgroups, row) } }
                if let calls, !calls.rows.isEmpty { section("Calls", calls) { row in callRow(calls, row) } }
            }
            .padding(12)
        }
        .background(Color(red: 0.03, green: 0.05, blue: 0.06).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear(perform: load)
        .onReceive(tick) { _ in load() }
    }

    private var active: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(latest == nil ? Color.gray : Self.accent).frame(width: 9, height: 9).shadow(color: latest == nil ? .clear : Self.accent, radius: 5)
                Text(receiver.status.mode).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.4f MHz", receiver.status.mhz)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let calls, let row = latest {
                Text(calls.value(row, "Source", "MY")).font(.system(size: 32, weight: .semibold, design: .monospaced)).foregroundStyle(Self.accent).lineLimit(1).minimumScaleFactor(0.5)
                Text("to \(calls.value(row, "Target", "UR"))").font(.body.monospaced())
            } else {
                Text(receiver.status.running ? (results.summary ?? "Listening…") : "Press power to start").font(.title3)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var stats: some View {
        let cards = (results.cards ?? []).filter { $0.count == 2 && !$0[1].isEmpty }
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(Array(cards.prefix(6).enumerated()), id: \.offset) { _, card in
                VStack(alignment: .leading, spacing: 1) {
                    Text(card[0]).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Text(card[1]).font(.footnote.monospaced()).lineLimit(1).minimumScaleFactor(0.7)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Self.surface, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func section<Row: View>(_ title: String, _ table: Results.Table, @ViewBuilder row: @escaping ([String]) -> Row) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(table.rows.suffix(40).reversed().enumerated()), id: \.offset) { _, values in
                row(values)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Self.surface, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func talkgroupRow(_ table: Results.Table, _ row: [String]) -> some View {
        HStack {
            Text(table.value(row, "Talkgroup")).font(.body.monospaced().weight(.medium)).foregroundStyle(Self.accent)
            Spacer()
            Text("\(table.value(row, "Calls")) calls").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func callRow(_ table: Results.Table, _ row: [String]) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(table.value(row, "Source", "MY")) → \(table.value(row, "Target", "UR"))").font(.footnote.monospaced())
                let note = table.value(row, "Alias / note", "Note", "Text", "Message")
                if !note.isEmpty { Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Text(table.value(row, "Seconds")).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func load() {
        if let new = Results.current() { results = new }
    }
}
