import Foundation
import OnAirCore
import Observation

/// What the native controls show. C++ owns the state; this is a copy read a few times a second.
@Observable
final class Receiver {
    struct Status: Decodable {
        var running = false
        var mhz = 0.0
        var mode = ""
        var source = ""
        var volume: Float = 1
        var muted = false
        var family = -1
        var error = ""
    }

    struct Rate: Decodable, Equatable {
        var usable = false
        var now = 0.0
        var chosen = 0.0
        var auto = 0.0
        var need = 0.0
        var rates: [Double] = []
    }

    private(set) var status = Status()
    private(set) var rate = Rate()
    private(set) var devices: [String] = []
    var videoFullscreen = false

    func refresh() {
        guard let text = onair_status_json() else { return }
        if let new = try? JSONDecoder().decode(Status.self, from: Data(String(cString: text).utf8)) { status = new }
        if let text = onair_rate_json(), let new = try? JSONDecoder().decode(Rate.self, from: Data(String(cString: text).utf8)), new != rate { rate = new }
        let names = (0..<onair_device_count()).map { String(cString: onair_device_name($0)) }
        if names != devices { devices = names }
    }

    func startStop() { onair_start_stop(); refresh() }
    func setRate(hz: Double) { onair_rate_set(hz); refresh() }
    func tune(mhz: Double) { onair_tune_mhz(mhz); refresh() }
    func setMuted(_ muted: Bool) { onair_set_volume(status.volume, muted); refresh() }
}
