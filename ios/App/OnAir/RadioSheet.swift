import OnAirCore
import SwiftUI

/// Adds a network radio. The native form sets what the desktop's Network radios window sets, and C++ does the rest.
struct RadioSheet: View {
    private enum Kind: Int, CaseIterable, Identifiable {
        case pluto = 0, rtlTcp = 1
        var id: Self { self }
        var label: String { self == .pluto ? "Pluto" : "rtl_tcp" }
        var defaultPort: String { self == .pluto ? "0" : "1234" }
    }

    @AppStorage("radioKind") private var kind = Kind.pluto
    @AppStorage("radioHost") private var host = "192.168.10.9"
    @AppStorage("radioPort") private var port = "0"
    @State private var busy = false
    @State private var problem = ""
    @Environment(\.dismiss) private var dismiss
    private let poll = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: kind) { _, new in port = new.defaultPort }
                TextField("Address", text: $host)
                    .keyboardType(.decimalPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if kind == .rtlTcp {
                    TextField("Port", text: $port).keyboardType(.numberPad)
                }
                if !problem.isEmpty {
                    Text(problem).foregroundStyle(.red)
                }
            }
            .navigationTitle("Radio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else { Button("Connect", action: connect).disabled(host.isEmpty) }
                }
            }
        }
        .presentationDetents([.medium])
        .onReceive(poll) { _ in check() }
    }

    private func connect() {
        problem = ""
        busy = true
        onair_net_connect(Int32(kind.rawValue), host, Int32(port) ?? 0)
    }

    private func check() {
        guard busy, !onair_net_busy() else { return }
        busy = false
        problem = String(cString: onair_net_error())
        if problem.isEmpty { dismiss() }
    }
}
