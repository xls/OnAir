import OnAirCore
import SwiftUI

/// The radios and sources C++ found, plus adding a network radio.
struct SourcePage: View {
    let receiver: Receiver
    @State private var showAdd = false

    private var names: [String] {
        (0..<onair_device_count()).map { String(cString: onair_device_name($0)) }
    }

    var body: some View {
        List {
            Section {
                ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                    Button {
                        onair_device_select(Int32(index))
                        receiver.refresh()
                    } label: {
                        HStack {
                            Text(name).foregroundStyle(.primary)
                            Spacer()
                            if name == receiver.status.source { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            Section {
                Button("Add network radio", systemImage: "plus") { showAdd = true }
            }
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
    }

    let receiver: Receiver
    let onPick: () -> Void
    @State private var query = ""
    private static let rows: [Row] = (0..<onair_mode_count()).map {
        Row(id: $0, name: String(cString: onair_mode_name($0)), group: String(cString: onair_mode_group($0)), blurb: String(cString: onair_mode_blurb($0)))
    }

    private var groups: [(String, [Row])] {
        var order: [String] = []
        var byGroup: [String: [Row]] = [:]
        for row in Self.rows where query.isEmpty || row.name.localizedCaseInsensitiveContains(query) || row.blurb.localizedCaseInsensitiveContains(query) {
            if byGroup[row.group] == nil { order.append(row.group) }
            byGroup[row.group, default: []].append(row)
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }

    var body: some View {
        List {
            ForEach(groups, id: \.0) { group, rows in
                Section(group) {
                    ForEach(rows) { row in
                        Button {
                            onair_mode_select(row.id)
                            receiver.refresh()
                            onPick()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.name).foregroundStyle(.primary)
                                    Text(row.blurb).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                if onair_mode_is_selected(row.id) { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search modes")
    }
}

struct SettingsPage: View {
    var body: some View {
        List {
            Section("OnAir") {
                Button("Full C++ settings") { onair_set_page(ONAIR_PAGE_SETTINGS) }
                Button("Full C++ interface") { onair_set_page(ONAIR_PAGE_TOUCH_SHELL) }
            }
        }
    }
}
