import OnAirCore
import SwiftUI

/// What the public databases know about an aircraft. Only its code and callsign are sent, and only when one is tapped.
@MainActor @Observable final class AircraftLookup {
    struct Info: Codable {
        var type = "", registration = "", owner = "", photo: URL?
        var airline = "", route = "", routeDetail = ""
        var found = Date()
        var isEmpty: Bool { type.isEmpty && route.isEmpty }
    }

    private struct AircraftReply: Decodable {
        struct Body: Decodable { let aircraft: Aircraft }
        struct Aircraft: Decodable {
            let type, manufacturer, registration: String?
            let registered_owner: String?
            let url_photo_thumbnail, url_photo: String?
        }
        let response: Body
    }

    private struct RouteReply: Decodable {
        struct Body: Decodable { let flightroute: Route }
        struct Route: Decodable {
            let airline: Airline?
            let origin, destination: Airport
        }
        struct Airline: Decodable { let name: String }
        struct Airport: Decodable { let municipality, iata_code: String }
        let response: Body
    }

    static let shared = AircraftLookup()
    private static let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("aircraft.json")
    private static let keptFor: TimeInterval = 30 * 86400   // a route changes; an aircraft rarely does
    private(set) var known: [String: Info]
    private var asked: Set<String>

    private init() {
        let saved = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode([String: Info].self, from: $0) } ?? [:]
        let fresh = saved.filter { Date().timeIntervalSince($0.value.found) < Self.keptFor }
        known = fresh
        asked = Set(fresh.keys)
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String) async -> T? {
        guard let url = URL(string: "https://api.adsbdb.com/v0/\(path)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Tuneit iOS", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)   // an unknown aircraft is a reply of another shape
    }

    func find(hex: String, callsign: String) {
        let key = hex + callsign
        guard asked.insert(key).inserted else { return }
        Task {
            var info = Info()
            if let a = await get(AircraftReply.self, "aircraft/\(hex)")?.response.aircraft {
                info.type = [a.manufacturer, a.type].compactMap { $0 }.joined(separator: " ")
                info.registration = a.registration ?? ""
                info.owner = a.registered_owner ?? ""
                info.photo = (a.url_photo ?? a.url_photo_thumbnail).flatMap(URL.init(string:))
            }
            if !callsign.isEmpty, let r = await get(RouteReply.self, "callsign/\(callsign)")?.response.flightroute {
                info.airline = r.airline?.name ?? ""
                info.route = "\(r.origin.municipality) → \(r.destination.municipality)"
                info.routeDetail = "\(r.origin.iata_code) to \(r.destination.iata_code)"
            }
            known[key] = info
            if info.isEmpty {
                asked.remove(key)   // nothing, perhaps no internet: asked again on the next tap, and not kept
            } else if let data = try? JSONEncoder().encode(known.filter { !$0.value.isEmpty }) {
                try? data.write(to: Self.file)
            }
        }
    }
}

/// One selected target: what the radio decoded, and for an aircraft what the online databases add.
struct TargetCard: View {
    let title: String
    let fields: [(String, String)]
    let hex: String?          // an aircraft's ICAO address
    let callsign: String
    let close: () -> Void
    private let lookup = AircraftLookup.shared

    private var info: AircraftLookup.Info? { hex.flatMap { lookup.known[$0 + callsign] } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    if let photo = info?.photo {
                        AsyncImage(url: photo) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Color.white.opacity(0.08)
                        }
                        .frame(width: 112, height: 74)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline.monospaced())
                        if let airline = info?.airline, !airline.isEmpty { Text(airline).font(.subheadline) }
                        else if let owner = info?.owner, !owner.isEmpty { Text(owner).font(.subheadline) }
                        if let route = info?.route, !route.isEmpty { Text(route).font(.subheadline.weight(.semibold)).foregroundStyle(.orange) }
                        if hex != nil && info == nil { Text("Looking up…").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                    Button(action: close) {
                        Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Close")
                }
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 6) {
                    if let info, !info.type.isEmpty { field("Aircraft", info.type) }
                    if let info, !info.registration.isEmpty { field("Registration", info.registration) }
                    ForEach(Array(fields.enumerated()), id: \.offset) { _, item in field(item.0, item.1) }
                }
                if let info, !info.route.isEmpty {
                    Text("Route \(info.routeDetail) comes from a public database by callsign and can be out of date.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
        }
        .background(Color(red: 0.07, green: 0.09, blue: 0.11))
        .onAppear(perform: ask)
        .onChange(of: hex) { ask() }
        .onChange(of: callsign) { ask() }
    }

    private func ask() { if let hex { lookup.find(hex: hex, callsign: callsign) } }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.footnote.monospacedDigit()).lineLimit(2)
        }
    }
}
