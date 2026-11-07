import MapKit
import OnAirCore
import SwiftUI

/// A moving thing OnAir has heard: an aircraft, a ship, a station, a sonde.
private struct Target: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let coordinate: CLLocationCoordinate2D?
    let heading: Double?

    static func == (a: Target, b: Target) -> Bool { a.id == b.id && a.title == b.title && a.detail == b.detail && a.coordinate?.latitude == b.coordinate?.latitude && a.coordinate?.longitude == b.coordinate?.longitude }

    /// Reads any of OnAir's tracking tables: a Lat and Lon pair, or one Position column of "lat, lon".
    static func all(from results: Results) -> [Target] {
        guard let table = results.tables?.first(where: { $0.column("Lat", "Pos", "Position") != nil }) else { return [] }
        return table.rows.compactMap { row in
            // the first filled column names a row of a table that uses none of the usual headings
            let id = table.value(row, "ICAO", "MMSI", "Callsign", "Call", "Id", "Name").isEmpty ? row.first { !$0.isEmpty } ?? "" : table.value(row, "ICAO", "MMSI", "Callsign", "Call", "Id", "Name")
            guard !id.isEmpty else { return nil }
            let title = table.value(row, "Callsign", "Call", "Name", "Flight", "ICAO", "MMSI")
            var coordinate: CLLocationCoordinate2D?
            if let lat = Double(table.value(row, "Lat")), let lon = Double(table.value(row, "Lon")) {
                coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            } else {
                let parts = table.value(row, "Pos", "Position").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if parts.count == 2 { coordinate = CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1]) }
            }
            var facts: [String] = []
            let altitude = table.value(row, "Alt ft"), metres = table.value(row, "Alt m"), speed = table.value(row, "Spd kt", "SOG kn", "Speed km/h"), kind = table.value(row, "Type", "Comment")
            if !altitude.isEmpty { facts.append("\(altitude) ft") }
            if !metres.isEmpty { facts.append("\(metres) m") }
            if !speed.isEmpty { facts.append("\(speed) \(table.column("Spd kt") != nil ? "kt" : "kn")") }
            if !kind.isEmpty { facts.append(kind) }
            return Target(id: id, title: title.isEmpty ? id : title, detail: facts.joined(separator: " · "), coordinate: coordinate, heading: Double(table.value(row, "Hdg")))
        }
    }
}

extension TrackerPage {
    /// What this screen would show, for the sweep.
    static func shown(_ results: Results) -> String {
        let all = Target.all(from: results)
        return "targets=\(all.count) located=\(all.filter { $0.coordinate != nil }.count)"
    }
}

/// Where the phone is, asked for once when a map opens.
@Observable final class StationLocation: NSObject, CLLocationManagerDelegate {
    private(set) var coordinate: CLLocationCoordinate2D?
    private(set) var denied = false
    private let manager = CLLocationManager()
    var found: ((CLLocationCoordinate2D) -> Void)?

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        coordinate = locations.last?.coordinate
        if let coordinate { found?(coordinate) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        denied = manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways { manager.requestLocation() }
    }
}

/// Anything with a position, on a live map.
struct TrackerPage: View {
    let receiver: Receiver
    @State private var results = Results()
    @State private var targets: [Target] = []
    @State private var selected: String?
    @State private var camera = MapCameraPosition.automatic
    @State private var location = StationLocation()
    @State private var tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var located: [Target] { targets.filter { $0.coordinate != nil } }
    private var symbol: String {
        switch receiver.status.family {
        case 14, 63: "ferry.fill"
        case 13: "balloon.fill"
        case 24: "antenna.radiowaves.left.and.right"
        case 56, 68: "airplane.circle.fill"
        default: "airplane"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Map(position: $camera, selection: $selected) {
                    ForEach(located) { target in
                        Annotation(target.title, coordinate: target.coordinate!) {
                            Image(systemName: symbol)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white)
                                .rotationEffect(.degrees((target.heading ?? 0) - (symbol == "airplane" ? 90 : 0)))
                                .padding(5)
                                .background(target.id == selected ? Color.orange : Color.blue, in: Circle())
                                .shadow(radius: 2)
                        }
                        .tag(target.id)
                    }
                }
                .mapStyle(.hybrid(elevation: .realistic))
                header
            }
            if let card {
                card.frame(maxHeight: 280)
            } else if targets.isEmpty {
                ScrollView {
                    VStack(spacing: 8) {
                        if let summary = results.summary { Text(summary).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                        if receiver.status.running { InstrumentGrid(results: results) }   // stopped, the core still reports the TV defaults
                        InstrumentTables(results: results)
                    }
                    .padding(10)
                }
                .frame(maxHeight: 250)
            } else {
                list.frame(maxHeight: 250)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            location.start()
            load()
        }
        .onChange(of: location.coordinate?.latitude) { centreOnStation() }
        .onChange(of: selected) { _, id in
            guard let id, let coordinate = targets.first(where: { $0.id == id })?.coordinate else { return }
            withAnimation { camera = .camera(MapCamera(centerCoordinate: coordinate, distance: 120_000)) }
        }
        .onReceive(tick) { _ in load() }
    }

    /// Starts around you: an aircraft receiver hears a few hundred kilometres.
    private func centreOnStation() {
        guard let here = location.coordinate else { return }
        camera = .region(MKCoordinateRegion(center: here, latitudinalMeters: 600_000, longitudinalMeters: 600_000))
    }

    private var header: some View {
        HStack {
            Text(receiver.status.running ? "\(targets.count) heard · \(located.count) on the map" : "Press power to start")
                .font(.footnote.weight(.medium))
            Spacer()
            Button {
                if location.coordinate != nil { centreOnStation() } else { camera = .automatic }
            } label: {
                Image(systemName: "location.fill")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(10)
    }

    /// The selected target, while it is still heard. Every decoded column with a value, in plain words.
    private var card: TargetCard? {
        guard let selected, let table = results.tables?.first(where: { $0.column("Lat", "Pos", "Position") != nil }),
              let target = targets.first(where: { $0.id == selected }) else { return nil }
        guard let row = table.rows.first(where: { $0.contains(selected) }) else { return nil }
        let names = ["Alt ft": "Altitude", "Spd kt": "Speed", "Hdg": "Heading", "VS fpm": "Climb", "Dist nm": "Distance", "Sqk": "Squawk", "Msgs": "Messages", "Age s": "Last heard"]
        let units = ["Alt ft": " ft", "Spd kt": " kt", "Hdg": "°", "VS fpm": " ft/min", "Dist nm": " nm", "Age s": " s ago"]
        let fields: [(String, String)] = zip(table.cols, row).compactMap { column, value in
            guard !value.isEmpty, column != "Callsign", column != "Lat", column != "Lon" else { return nil }
            return (names[column] ?? column, value + (units[column] ?? ""))
        }
        let hex = table.column("ICAO") != nil && selected.count == 6 ? selected : nil
        return TargetCard(title: target.title, fields: fields, hex: hex, callsign: table.value(row, "Callsign").trimmingCharacters(in: .whitespaces)) { self.selected = nil }
    }

    private var list: some View {
        List(targets, selection: $selected) { target in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.title).font(.body.weight(.medium).monospaced())
                        if !target.detail.isEmpty { Text(target.detail).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if target.coordinate != nil { Image(systemName: "mappin").foregroundStyle(.secondary) }
                }
                .tag(target.id)
            }
            .listStyle(.plain)
    }

    private func load() {
        guard let new = Results.current() else { return }
        results = new
        let next = Target.all(from: new)
        if next != targets { targets = next }
        if let id = selected, !next.contains(where: { $0.id == id }) { selected = nil }   // it has gone out of range
        if selected == nil, ProcessInfo.processInfo.arguments.contains("--select-first") { selected = located.first?.id }
    }
}
