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
        var scan = false
    }

    struct Rate: Decodable, Equatable {
        var usable = false
        var now = 0.0
        var chosen = 0.0
        var auto = 0.0
        var need = 0.0
        var minHz = 0.0   // what the radio can tune, 0 = not known
        var maxHz = 0.0
        var rates: [Double] = []
    }

    private(set) var status = Status()
    private(set) var rate = Rate()
    private(set) var filterBand: ClosedRange<Double>?
    private(set) var devices: [String] = []
    var videoFullscreen = false

    func refresh() {
        guard let text = onair_status_json() else { return }
        if let new = try? JSONDecoder().decode(Status.self, from: Data(String(cString: text).utf8)) { status = new }
        if let text = onair_rate_json(), let new = try? JSONDecoder().decode(Rate.self, from: Data(String(cString: text).utf8)), new != rate { rate = new }
        var low = 0.0, high = 0.0
        let band = onair_filter_band(&low, &high) && high > low ? low...high : nil
        if band != filterBand { filterBand = band }
        let names = (0..<onair_device_count()).map { String(cString: onair_device_name($0)) }
        if names != devices { devices = names }
    }

    func startStop() { onair_start_stop(); refresh() }
    func canReach(mhz: Double) -> Bool {
        let hz = mhz * 1e6
        return hz >= rate.minHz && (rate.maxHz == 0 || hz <= rate.maxHz)
    }

    func setRate(hz: Double) { onair_rate_set(hz); refresh() }
    func tune(mhz: Double) { onair_tune_mhz(mhz); refresh() }
    func setMuted(_ muted: Bool) { onair_set_volume(status.volume, muted); refresh() }
}

/// While a full-height sheet covers the page, the page holds its last picture instead of drawing, so the sheet scrolls smoothly and the page is
/// there at once when the sheet goes. Sound and decoding carry on.
@MainActor @Observable final class UIFreeze {
    static let shared = UIFreeze()
    var on = false
}
