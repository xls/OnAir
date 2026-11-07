import OnAirCore
import SwiftUI

/// Sensors, networks and cells: one live tile for each thing heard.
struct DevicesPage: View {
    private struct Device: Identifiable {
        let id: String
        let name: String
        let facts: [(String, String)]
        let strength: String
    }

    let receiver: Receiver
    @State private var results = Results()
    @State private var open: String?
    @State private var tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private static let accent = Color(red: 0.36, green: 0.75, blue: 1)

    private var table: Results.Table? { (results.tables ?? []).filter { !$0.rows.isEmpty }.max { $0.rows.count < $1.rows.count } }

    private var devices: [Device] {
        guard let table else { return [] }
        return table.rows.enumerated().map { index, row in
            let name = table.value(row, "Name", "SSID", "Model", "Id", "Address", "Device", "MHz")
            let strength = table.value(row, "RSSI", "Level dB", "SNR dB", "Level")
            var facts: [(String, String)] = []
            for (i, column) in table.cols.enumerated() where i < row.count && !row[i].isEmpty && row[i] != name && row[i] != strength { facts.append((column, row[i])) }
            return Device(id: "\(index)-\(name)", name: name.isEmpty ? (row.first ?? "") : name, facts: facts, strength: strength)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                header
                if receiver.status.running { InstrumentGrid(results: results) }   // stopped, the core still reports the TV defaults
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(devices) { tile($0) }
                }
            }
            .padding(12)
        }
        .background(Color(red: 0.03, green: 0.04, blue: 0.07).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear(perform: load)
        .onReceive(tick) { _ in load() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "sensor.tag.radiowaves.forward.fill").foregroundStyle(Self.accent)
            Text(receiver.status.running ? "\(devices.count) heard" : "Press power to start").font(.headline)
            Spacer()
            Text(receiver.status.mode).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func tile(_ device: Device) -> some View {
        Button {
            withAnimation(.snappy) { open = open == device.id ? nil : device.id }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(device.name).font(.footnote.weight(.semibold)).foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.leading)
                    Spacer()
                }
                if !device.strength.isEmpty {
                    Text(device.strength).font(.caption2.monospacedDigit()).foregroundStyle(Self.accent)
                }
                ForEach(Array(device.facts.prefix(open == device.id ? 20 : 2).enumerated()), id: \.offset) { _, fact in
                    HStack(alignment: .top) {
                        Text(fact.0).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(fact.1).foregroundStyle(.white).multilineTextAlignment(.trailing)
                    }
                    .font(.caption2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(Color(red: 0.09, green: 0.11, blue: 0.16), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func load() {
        if let new = Results.current() { results = new }
    }
}
