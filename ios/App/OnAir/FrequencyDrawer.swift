import OnAirCore
import SwiftUI

/// OnAir's channels and known frequencies for the current mode.
struct ChannelPlan: Decodable {
    struct Plan: Decodable, Identifiable {
        let id, name: String
    }

    struct Channel: Decodable, Identifiable {
        var id: String { label }
        let label: String
        let mhz, bandwidth: Double
    }

    struct Known: Decodable, Identifiable {
        var id: String { "\(mhz)\(name)" }
        let mhz: Double
        let name, notes, region: String
    }

    var plan = ""
    var planName = ""
    var plans: [Plan] = []
    var channels: [Channel] = []
    var known: [Known] = []

    static func current() -> ChannelPlan {
        guard let text = onair_channels_json(),
              let plan = try? JSONDecoder().decode(ChannelPlan.self, from: Data(String(cString: text).utf8)) else { return ChannelPlan() }
        return plan
    }
}

/// Pulls up from the frequency window: type a frequency, or pick from what OnAir knows for this mode.
struct FrequencyDrawer: View {
    let receiver: Receiver
    @Environment(\.dismiss) private var dismiss
    @State private var plan = ChannelPlan()
    @State private var typed = ""
    @AppStorage("frequencyUnit") private var unit = "MHz"
    private static let units: [(name: String, mhz: Double)] = [("kHz", 0.001), ("MHz", 1), ("GHz", 1000)]
    @State private var query = ""

    private var channels: [ChannelPlan.Channel] {
        plan.channels.filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) || String($0.mhz).contains(query) }
    }

    private var known: [ChannelPlan.Known] {
        plan.known.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.notes.localizedCaseInsensitiveContains(query) || String($0.mhz).contains(query) }
    }

    var body: some View {
        PanelPage {
            HStack(spacing: 8) {
                GlassWindow(corner: 6) {
                    TextField("", text: $typed, prompt: Text("FREQUENCY \(unit)").foregroundStyle(RadioTheme.amber.opacity(0.4)))
                        .font(.system(size: 20, weight: .medium, design: .monospaced))
                        .foregroundStyle(RadioTheme.amber)
                        .keyboardType(.decimalPad)
                        .padding(10)
                }
                HardwareKey(lit: !typed.isEmpty, action: tuneTyped) {
                    EngravedLabel(text: "TUNE", size: 9)
                }
                .frame(width: 76, height: 52)
            }
            HStack(spacing: 6) {
                ForEach(Self.units, id: \.name) { item in
                    HardwareKey(lit: unit == item.name, led: RadioTheme.amber, action: { unit = item.name }) {
                        EngravedLabel(text: item.name, size: 9)
                    }
                    .frame(height: 38)
                }
            }
            if plan.channels.count + plan.known.count > 12 {
                GlassWindow(corner: 6) {
                    TextField("", text: $query, prompt: Text("SEARCH").foregroundStyle(RadioTheme.amber.opacity(0.4)))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(RadioTheme.amber)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(9)
                }
            }
            if !plan.plans.isEmpty {
                PanelSection(title: "Region") {
                    PanelRow(label: "Channel plan") {
                        SelectorWindow(selected: plan.planName, options: plan.plans.map(\.name)) { index in
                            onair_channel_plan_set(plan.plans[index].id)
                            plan = ChannelPlan.current()
                        }
                    }
                }
            }
            if !channels.isEmpty {
                PanelSection(title: "Channels") {
                    ForEach(channels) { channel in
                        Button {
                            onair_channel_pick(channel.mhz, channel.bandwidth)
                            finish()
                        } label: {
                            PanelRow(label: "Channel \(channel.label)", help: String(format: "%g MHz wide", channel.bandwidth)) {
                                Text(String(format: "%.3f", channel.mhz)).font(.system(size: 13, design: .monospaced)).foregroundStyle(RadioTheme.amber)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !known.isEmpty {
                PanelSection(title: "Known frequencies") {
                    ForEach(known) { entry in
                        Button {
                            onair_channel_pick(entry.mhz, 0)
                            finish()
                        } label: {
                            PanelRow(label: entry.name, help: entry.notes) {
                                Text(String(format: "%.3f", entry.mhz)).font(.system(size: 13, design: .monospaced)).foregroundStyle(RadioTheme.amber)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            plan = ChannelPlan.current()
            typed = ""
        }
    }

    private func tuneTyped() {
        guard let value = Double(typed.replacingOccurrences(of: ",", with: ".")) else { return }
        receiver.tune(mhz: value * (Self.units.first { $0.name == unit }?.mhz ?? 1))
        finish()
    }

    private func finish() {
        receiver.refresh()
        dismiss()
    }
}
