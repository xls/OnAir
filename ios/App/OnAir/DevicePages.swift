import OnAirCore
import SwiftUI

/// The radios and sources C++ found, plus adding a network radio.
struct SourcePage: View {
    let receiver: Receiver
    @State private var showAdd = false

    var body: some View {
        PanelPage {
            PanelSection(title: "Source") {
                ForEach(Array(receiver.devices.enumerated()), id: \.offset) { index, name in
                    Button {
                        onair_device_select(Int32(index))
                        receiver.refresh()
                    } label: {
                        PanelRow(label: name) {
                            Circle()
                                .fill(name == receiver.status.source ? Color.green : Color(white: 0.18))
                                .frame(width: 10, height: 10)
                                .shadow(color: name == receiver.status.source ? .green : .clear, radius: 5)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HardwareKey(action: { showAdd = true }) {
                EngravedLabel(text: "ADD NETWORK RADIO", size: 9)
            }
            .frame(height: 50)
        }
        .sheet(isPresented: $showAdd) {
            RadioSheet()
        }
    }
}

/// Every mode, grouped and searchable. All 183 come from the C++ table.
struct ModeBrowser: View {
    private struct Row: Identifiable {
        let id: Int32
        let name, group, blurb: String
        let native: Bool
    }

    let receiver: Receiver
    let onPick: () -> Void
    @State private var query = ""
    @AppStorage("modesNativeOnly") private var nativeOnly = false
    private static let rows: [Row] = (0..<onair_mode_count()).map {
        let name = String(cString: onair_mode_name($0))
        return Row(id: $0, name: name, group: String(cString: onair_mode_group($0)), blurb: String(cString: onair_mode_blurb($0)),
                   native: OnAirFamily.hasNativeScreen(family: Int(onair_mode_family($0)), mode: name))
    }

    private var groups: [(String, [Row])] {
        var order: [String] = []
        var byGroup: [String: [Row]] = [:]
        for row in Self.rows where (!nativeOnly || row.native) && (query.isEmpty || row.name.localizedCaseInsensitiveContains(query) || row.blurb.localizedCaseInsensitiveContains(query)) {
            if byGroup[row.group] == nil { order.append(row.group) }
            byGroup[row.group, default: []].append(row)
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }

    var body: some View {
        PanelPage {
            GlassWindow(corner: 6) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(RadioTheme.amber)
                    TextField("", text: $query, prompt: Text("SEARCH MODES").foregroundStyle(RadioTheme.amber.opacity(0.4)))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(RadioTheme.amber)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(9)
            }
            HStack(spacing: 8) {
                HardwareKey(lit: nativeOnly, led: .green, action: { nativeOnly.toggle() }) {
                    EngravedLabel(text: "NATIVE ONLY", size: 9)
                }
                .frame(height: 46)
                Text("\(Self.rows.filter(\.native).count) of \(Self.rows.count) native")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(white: 0.08))
                    .shadow(color: .white.opacity(0.4), radius: 0, y: 0.7)
            }
            ForEach(groups, id: \.0) { group, rows in
                PanelSection(title: group) {
                    ForEach(rows) { row in
                        Button {
                            onair_mode_select(row.id)
                            receiver.refresh()
                            onPick()
                        } label: {
                            PanelRow(label: row.name, help: row.blurb) {
                                HStack(spacing: 8) {
                                    Text(row.native ? "NATIVE" : "BASIC")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(row.native ? Color.green : Color(white: 0.5))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(row.native ? Color.green.opacity(0.7) : Color(white: 0.3), lineWidth: 1))
                                    Circle()
                                        .fill(onair_mode_is_selected(row.id) ? Color.green : Color(white: 0.18))
                                        .frame(width: 10, height: 10)
                                        .shadow(color: onair_mode_is_selected(row.id) ? .green : .clear, radius: 5)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
