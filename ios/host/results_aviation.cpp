// Cards and tables of the aviation, marine and navigation modes for the native screens, with the desktop's column names.
// The TrackerPage reads the first table with a Lat / Position column, the TexterPage the first table with a Text / Message column: those tables come first.
// Positions go out in degrees, "Alt ft" in feet and "Spd kt" in knots whatever the mode measures, because the tracker prints those units.
#include "results_kit.h"
#include "dect2/flarm/flarm_proto.h"
#include "dect2/ils/ils.h"
#include "dect2/marinevhf/marinevhf_channels.h"
#include "dect2/rid/rid_proto.h"
#include <algorithm>
#include <cmath>
#include <cstdarg>
#include <ctime>
#include <set>
#include <vector>

namespace onair::results {
using namespace dect2;

namespace {

constexpr size_t kMaxRows = 200;

__attribute__((format(printf, 1, 2))) std::string fmt(const char* f, ...) {
    char b[512];
    va_list ap; va_start(ap, f); vsnprintf(b, sizeof b, f, ap); va_end(ap);
    return b;
}
std::string n(uint64_t v) { return std::to_string(v); }
std::string yes(bool v) { return v ? "yes" : "no"; }
std::string mhz(double hz) { return fmt("%.3f", hz / 1e6); }
std::string db(double v, const char* unit) { return fmt("%.1f %s", v, unit); }
std::string utc(int64_t wall) {
    if (wall <= 0) return "";   // a file has no clock
    time_t t = (time_t)wall; struct tm tm; gmtime_r(&t, &tm);
    return fmt("%02d:%02d:%02d", tm.tm_hour, tm.tm_min, tm.tm_sec);
}
std::string ago(double s) {
    if (s < 0) return "";
    return s < 90 ? fmt("%.0f s", s) : s < 5400 ? fmt("%.0f min", s / 60) : fmt("%.1f h", s / 3600);
}
std::string latlon(double lat, double lon) { return fmt("%.5f, %.5f", lat, lon); }
std::string feet(double metres) { return fmt("%.0f", metres * 3.28084); }

// Telemetry vectors come in both orders; every table goes out newest first
template <class V, class F> void newestFirst(const V& v, F f) {
    size_t i = 0;
    for (const auto& x : v) { if (i++ >= kMaxRows) break; f(x); }
}
template <class V, class F> void newestLast(const V& v, F f) {
    size_t i = 0;
    for (auto it = v.rbegin(); it != v.rend(); ++it) { if (i++ >= kMaxRows) break; f(*it); }
}

void adsbTable(Out& o, const char* name, const AdsbTelemetry& a) {
    Table t(name, {"ICAO", "Callsign", "Alt ft", "Spd kt", "Hdg", "VS fpm", "Lat", "Lon", "Dist nm", "Sqk", "Msgs", "Age s"});
    newestFirst(a.aircraft, [&](const AdsbAircraft& x) {
        t.row({fmt("%06X", x.icao & 0xFFFFFF), x.callsign,
               x.hasAlt ? std::to_string(x.altFt) : "", x.hasSpeed ? fmt("%.0f", (double)x.speedKt) : "", x.hasHeading ? fmt("%.0f", (double)x.headingDeg) : "",
               x.hasVrate ? std::to_string(x.vrateFpm) : "", x.hasPos ? fmt("%.5f", x.lat) : "", x.hasPos ? fmt("%.5f", x.lon) : "",
               x.hasRange ? fmt("%.0f", (double)x.distNm) : "", x.hasSquawk ? fmt("%04d", x.squawk) : "", n(x.messages), fmt("%.0f", (double)x.ageSec)});
    });
    o.table(t);
}

void uplink(Out& o, const UplinkTelemetry& a) {
    o.card("Interrogations", n(a.blocksOk));
    o.card("Mode S", n(a.modeS));
    o.card("Mode A", n(a.modeA));
    o.card("Mode C", n(a.modeC));
    o.card("Intermode", n(a.intermodeAcs + a.intermodeAc));
    o.card("Sidelobe", n(a.modeAcSidelobe + a.modeSSidelobe));
    o.card("Interrogators", n(a.interrogators.size()));
    o.card("Aircraft", n(a.aircraft.size()));
    o.card("Level", db(a.levelDb, "dBFS"));
    o.card("Noise", db(a.noiseDb, "dBFS"));

    Table in("Interrogators", {"Code", "Heard", "Rate", "Rotation", "Level", "Last", "All-call / roll-call", "Mode A / C, sidelobe"});
    newestFirst(a.interrogators, [&](const UplinkInterrogator& i) {
        std::string code = i.kind == 1 ? "Mode A/C" : i.kind == 2 ? "intermode" : i.ii >= 0 ? fmt("II %d", i.ii) : fmt("SI %d", i.si);
        in.row({code, n(i.count), fmt("%.1f /s", (double)i.ratePerSec), i.periodSec > 0 ? fmt("%.2f s", (double)i.periodSec) : "", db(i.levelDb, "dBFS"),
                ago(a.timeSec - i.lastSec), n(i.allCalls) + " / " + n(i.rollCalls), n(i.modeA) + " / " + n(i.modeC) + ", " + n(i.sidelobe)});
    });
    o.table(in);

    Table ac("Aircraft", {"Address", "Interrogations", "Formats", "Registers", "By", "Last"});
    newestFirst(a.aircraft, [&](const UplinkAircraft& x) {
        std::string formats, registers;
        for (int u : {0, 4, 5, 16, 20, 21, 24}) if (x.uf[u]) formats += (formats.empty() ? "" : " ") + fmt("UF%d:%llu", u, (unsigned long long)x.uf[u]);
        for (const std::string& r : x.registers) registers += (registers.empty() ? "" : " ") + r;
        ac.row({fmt("%06X", x.addr & 0xFFFFFF) + (x.confirmed ? "" : " ?"), n(x.count), formats, registers, x.interrogators, ago(a.timeSec - x.lastSec)});
    });
    o.table(ac);

    Table tc("TCAS", {"Time", "Format", "From", "To", "What"});
    newestLast(a.tcas, [&](const UplinkTcas& x) {
        tc.row({fmt("%.1f s", x.sec), fmt("UF%d", x.uf), x.from ? fmt("%06X", x.from & 0xFFFFFF) : "", x.to ? fmt("%06X", x.to & 0xFFFFFF) : "", x.text});
    });
    o.table(tc);

    Table lg("Log", {"Time", "Level", "Address", "Interrogation"});
    newestLast(a.log, [&](const UplinkLogLine& x) {
        lg.row({fmt("%.1f s", x.sec), db(x.levelDb, "dBFS"), x.uf >= 0 && x.addr ? fmt("%06X", x.addr & 0xFFFFFF) : "", x.text});
    });
    o.table(lg);
}

void modeAc(Out& o, const ModeAcTelemetry& a) {
    o.card("Codes", n(a.codeCount));
    o.card("Matched to Mode S", n(a.matched));
    o.card("Replies per second", fmt("%.1f", (double)a.repliesPerSec));
    o.card("SNR", db(a.snrDb, "dB"));
    o.card("Level", db(a.levelDbfs, "dBFS"));
    o.card("Noise", db(a.noiseDbfs, "dBFS"));
    o.card("Mode S aircraft", n(a.adsb.aircraftCount));
    o.card("Mode S messages", n(a.modeSGood));

    Table t("Codes", {"Squawk", "Alt ft", "Type", "Ident", "Replies", "dBFS", "Age", "Aircraft"});
    newestFirst(a.codes, [&](const ModeAcCode& c) {
        std::string who = !c.icao ? "" : c.callsign.empty() ? fmt("%06X", c.icao & 0xFFFFFF) : c.callsign;
        t.row({fmt("%04d", c.squawk), c.kind != 1 && c.altValid ? std::to_string(c.altFt) : "", c.kind == 1 ? "Mode A" : c.kind == 2 ? "Mode C" : "A or C", c.spi ? "SPI" : "",
               n(c.count), fmt("%.0f", (double)c.levelDbfs), fmt("%.0f s", (double)c.ageSec), who});
    });
    o.table(t);
    adsbTable(o, "Mode S aircraft", a.adsb);
}

void vdl4(Out& o, const Vdl4Telemetry& a) {
    int inBand = 0, active = 0;
    for (const Vdl4ChannelInfo& c : a.channels) { inBand += c.inBand; active += c.active; }
    o.card("State", a.state == 2 ? "decoding" : a.state == 1 ? "bursts" : "listening");
    o.card("Frames", n(a.blocksOk));
    o.card("Bad", n(a.blocksBad));
    o.card("Channels active", std::to_string(active) + " of " + std::to_string(inBand));
    o.card("Aircraft", n(a.aircraft.size()));
    o.card("Ground stations", n(a.stations.size()));
    o.card("Positions", n(a.positionsTotal));

    Table m("Messages", {"Time UTC", "MHz", "From", "To", "Type", "Text"});
    newestFirst(a.messages, [&](const Vdl4Message& x) {
        std::string line = x.summary;
        if (x.hasUser && !x.userText.empty()) line += (line.empty() ? "" : ": ") + x.userText;
        m.row({utc(x.wallTime), mhz(x.freqHz), fmt("%06X", x.src), x.uplink ? "Aircraft" : "", x.msgName, line});
    });
    o.table(m);

    Table ac("Aircraft", {"Id", "Lat", "Lon", "Alt ft", "Msgs", "MHz", "Level", "Last"});
    newestFirst(a.aircraft, [&](const Vdl4Aircraft& x) {
        ac.row({fmt("%06X", x.addr), x.hasPos ? fmt("%.5f", x.lat) : "", x.hasPos ? fmt("%.5f", x.lon) : "", x.hasAlt ? std::to_string(x.altFt) : "", n(x.messages),
                mhz(x.freqHz), db(x.levelDb, "dB"), ago(a.nowSec - x.lastHeardSec)});
    });
    o.table(ac);

    Table gs("Ground stations", {"Id", "Lat", "Lon", "Msgs", "MHz", "Level", "Last"});
    newestFirst(a.stations, [&](const Vdl4GroundStation& x) {
        gs.row({fmt("%06X", x.addr), x.hasPos ? fmt("%.5f", x.lat) : "", x.hasPos ? fmt("%.5f", x.lon) : "", n(x.messages), mhz(x.freqHz), db(x.levelDb, "dB"), ago(a.nowSec - x.lastHeardSec)});
    });
    o.table(gs);

    Table ch("Channels", {"MHz", "State", "Level", "Noise", "SNR", "Bursts", "Good", "Bad", "Frames"});
    newestFirst(a.channels, [&](const Vdl4ChannelInfo& c) {
        ch.row({mhz(c.freqHz), !c.inBand ? "out of band" : c.active ? "active" : "idle", db(c.levelDb, "dB"), db(c.noiseDb, "dB"), db(c.snrDb, "dB"), n(c.bursts), n(c.good), n(c.bad), n(c.frames)});
    });
    o.table(ch);
}

void airband(Out& o, const AirbandTelemetry& a) {
    int inBand = 0, open = 0;
    for (const AirbandChannelState& c : a.channels) { inBand += c.inBand; open += c.open; }
    o.card("State", a.state == 2 ? "channel open" : a.state == 1 ? (a.scan ? "scanning" : "listening") : "no channel in the band");
    o.card("Channels in band", std::to_string(inBand) + " of " + std::to_string(a.channels.size()));
    o.card("Open", std::to_string(open));
    o.card("Transmissions", n(a.blocksOk));
    o.card("Best C/N", db(a.snrDb, "dB"));
    o.card("Level", db(a.levelDb, "dBFS"));
    o.card("Squelch", db(a.squelchDb, "dB"));
    if (a.tuneKnown) o.card("Tuning error", fmt("%+.0f Hz", a.cfoHz));

    Table t("Channels", {"Channel", "Name", "Level", "C/N", "State", "Carrier", "Heard"});
    newestFirst(a.channels, [&](const AirbandChannelState& c) {
        std::string state = !c.inBand ? "out of band" : c.heterodyne ? "two carriers" : c.playing ? "playing" : c.open ? "open" : "closed";
        t.row({c.name, c.label, db(c.levelDb, "dBFS"), db(c.snrDb, "dB"), state, fmt("%+.0f Hz", (double)c.carrierHz), n(c.transmissions)});
    });
    o.table(t);

    Table lg("Activity", {"Time UTC", "Channel", "Name", "Length", "C/N", "Level"});
    newestFirst(a.activity, [&](const AirbandActivity& x) {
        lg.row({utc(x.wallTime), x.name, x.label, x.durSec > 0 ? fmt("%.1f s", x.durSec) : "on air", db(x.snrDb, "dB"), db(x.levelDb, "dBFS")});
    });
    o.table(lg);

    Table s("Seen, not in the list", {"Channel", "Level", "Heard", "Last"});
    newestFirst(a.seen, [&](const AirbandSeen& x) {
        s.row({x.name, fmt("%+.1f dB", (double)x.excessDb), n(x.hits), x.activeNow ? "now" : ago(a.timeSec - x.lastSec)});
    });
    o.table(s);
}

void vor(Out& o, const VorTelemetry& a) {
    o.card("State", a.state == 2 ? "measuring" : a.state == 1 ? "carrier" : "no carrier");
    o.card("Function", navFunctionName(a.function));
    if (!a.ident.empty() || !a.identLast.empty()) o.card("Ident", a.ident.empty() ? a.identLast + " ?" : a.ident);
    if (a.identWpm > 0) o.card("Ident speed", fmt("%.0f WPM", (double)a.identWpm));
    if (a.dialHz > 0) o.card("Frequency", mhz(a.dialHz) + " MHz");
    o.card("C/N", db(a.snrDb, "dB"));
    o.card("Level", db(a.levelDb, "dBFS"));
    o.card("Carrier offset", fmt("%+.0f Hz", a.cfoHz));
    if (a.function == NavFunction::Vor && a.vorValid) {
        o.card("Radial (from)", fmt("%05.1f deg", a.radialDeg));
        o.card("Bearing to", fmt("%05.1f deg", vorToBearing(a.radialDeg)));
        o.card("Scatter", fmt("%.2f deg", a.radialStdDeg));
        o.card("30 Hz AM", fmt("%.0f %%", a.am30 * 100.0));
        o.card("9960 Hz AM", fmt("%.0f %%", a.sub9960 * 100.0));
        o.card("FM deviation", fmt("%.0f Hz", (double)a.fmDevHz));
    }
    if ((a.function == NavFunction::Localizer || a.function == NavFunction::Glideslope) && a.ilsValid) {
        const bool gs = a.function == NavFunction::Glideslope;
        const double fullScale = gs ? kIlsGsFullScaleDdm : kIlsLocFullScaleDdm;
        o.card("DDM", fmt("%+.4f", a.ddm));
        o.card("Needle", fmt("%s %.0f %% of full scale", gs ? (a.ddm > 0 ? "fly down" : "fly up") : (a.ddm > 0 ? "fly right" : "fly left"), std::min(100.0, std::fabs(a.ddm) / fullScale * 100)));
        o.card("SDM", fmt("%.3f", a.sdm));
        o.card("90 Hz", fmt("%.2f %%", a.m90 * 100));
        o.card("150 Hz", fmt("%.2f %%", a.m150 * 100));
        o.card("Scatter", fmt("%.4f", a.ddmStd));
    }
    if (a.function == NavFunction::Marker) {
        static const char* const names[4] = {"none", "outer (400 Hz)", "middle (1300 Hz)", "inner (3000 Hz)"};
        o.card("Marker", names[a.marker & 3]);
        o.card("Tone keyed", yes(a.markerOn));
        o.card("Depth", fmt("%.0f %%", a.markerDepth * 100.0));
    }
}

void ndb(Out& o, const NdbTelemetry& a) {
    o.card("State", a.state == 2 ? "ident repeated" : a.state == 1 ? "carrier" : "no carrier");
    if (!a.ident.empty()) o.card("Ident", a.ident);
    if (!a.partial.empty()) o.card("Keying now", a.partial);
    o.card("Tone", ndbToneName(a));
    if (a.wpm > 0) o.card("Speed", fmt("%.0f WPM", (double)a.wpm));
    o.card("Depth", fmt("%.0f %%", a.depth * 100.0));
    o.card("SNR", db(a.snrDb, "dB"));
    o.card("Level", db(a.levelDb, "dBFS"));
    o.card("Carrier offset", fmt("%+.1f Hz", a.cfoHz));
    o.card("Idents accepted", n(a.blocksOk));
    if (!a.text.empty()) o.card("Reading", a.text);

    Table t("Idents", {"Ident", "Heard"});
    std::vector<std::string> order;   // newest first, each ident once
    for (auto it = a.history.rbegin(); it != a.history.rend(); ++it) if (std::find(order.begin(), order.end(), *it) == order.end()) order.push_back(*it);
    newestFirst(order, [&](const std::string& id) { t.row({id, n((uint64_t)std::count(a.history.begin(), a.history.end(), id))}); });
    o.table(t);
}

void dme(Out& o, const DmeTelemetry& a) {
    o.card("State", a.state == 2 ? "ident read" : a.state == 1 ? "pulse pairs" : "no pulse pairs");
    o.card("Channel", dmeChannelLabel(a));
    if (!a.ident.empty()) o.card("Ident", a.ident);
    o.card("Pair rate", fmt("%.0f pairs/s", a.pairRatePps));
    o.card("X pairs", std::to_string(a.pairsX));
    o.card("Y pairs", std::to_string(a.pairsY));
    if (a.pairsYInterrogation) o.card("Aircraft interrogations", std::to_string(a.pairsYInterrogation));
    if (a.identIntervalUs > 0) o.card("Ident interval", fmt("%.1f us", a.identIntervalUs));
    o.card("Ident keyed", yes(a.identKeyed));
    if (a.centerHz > 0) o.card("Frequency", mhz(a.centerHz) + " MHz");
    o.card("Level", db(a.levelDb, "dB"));
}

void rid(Out& o, const RidTelemetry& a) {
    o.card("Drones", n(a.drones.size()));
    o.card("Messages", n(a.blocksOk));
    o.card("Bad", n(a.blocksBad));
    o.card("BLE packets", n(a.blePackets));
    o.card("Wi-Fi frames", n(a.wifiFrames));
    o.card("With Remote ID", n(a.bleRid) + " BLE, " + n(a.wifiRid) + " Wi-Fi");
    if (a.bleChannel) o.card("BLE channel", std::to_string(a.bleChannel));
    if (a.wifiChannel) o.card("Wi-Fi channel", std::to_string(a.wifiChannel));
    o.card("Level", db(a.levelDb, "dBFS"));

    Table t("Drones", {"Id", "Name", "Type", "Status", "Lat", "Lon", "Alt ft", "Height m", "Spd kt", "Hdg", "VS m/s", "Operator", "Operator ID", "Via", "Level", "Msgs", "Last seen"});
    newestFirst(a.drones, [&](const RidDrone& d) {
        const std::string id = !d.serial.empty() ? d.serial : !d.sessionId.empty() ? d.sessionId : !d.caaId.empty() ? d.caaId : !d.utmId.empty() ? d.utmId : d.mac;
        const float alt = d.altGeo > -1000 ? d.altGeo : d.altBaro;
        t.row({id, d.selfId, d.uaType < 0 ? "" : rid::uaTypeName(d.uaType), rid::statusName(d.status), d.hasPos ? fmt("%.6f", d.lat) : "", d.hasPos ? fmt("%.6f", d.lon) : "",
               alt > -1000 ? feet(alt) : "", d.height > -1000 ? fmt("%.0f", (double)d.height) : "", d.speed >= 0 ? fmt("%.1f", d.speed * 1.94384) : "",
               d.direction >= 0 ? fmt("%.0f", (double)d.direction) : "", d.vspeedValid ? fmt("%+.1f", (double)d.vspeed) : "", d.hasOperator ? latlon(d.opLat, d.opLon) : "", d.operatorId,
               d.viaBle && d.viaWifi ? "BLE + Wi-Fi" : d.viaBle ? "BLE" : "Wi-Fi", fmt("%.0f", (double)d.rssi), n(d.messages), ago(a.timeSec - d.lastSec)});
    });
    o.table(t);

    Table lg("Messages", {"Time UTC", "From", "Via", "Level", "Text"});
    newestFirst(a.log, [&](const RidMsgLog& x) {
        lg.row({utc(x.wallTime), x.mac, std::string(x.transport ? "Wi-Fi" : "BLE") + (x.channel ? " " + std::to_string(x.channel) : ""), fmt("%.0f", (double)x.rssi), x.info});
    });
    o.table(lg);
}

void uat(Out& o, const UatTelemetry& a) {
    o.card("Aircraft", n(a.aircraftCount));
    o.card("With position", n(a.withPosition));
    o.card("Messages per second", fmt("%.1f", (double)a.msgsPerSec));
    o.card("FIS-B", n(a.fisbCount));
    o.card("TIS-B", n(a.tisbCount));
    o.card("Frames", n(a.frameCount));
    o.card("SNR", db(a.snrDb, "dB"));
    o.card("Noise", db(a.noiseDbfs, "dBFS"));

    Table t("Aircraft", {"ICAO", "Callsign", "Alt ft", "Spd kt", "Hdg", "VS fpm", "Lat", "Lon", "Dist nm", "Sqk", "Type", "Msgs", "Age s"});
    newestFirst(a.aircraft, [&](const UatAircraft& x) {
        t.row({fmt("%06X", x.icao & 0xFFFFFF), x.callsign, x.hasAlt ? std::to_string(x.altFt) : x.hasGeoAlt ? std::to_string(x.geoAltFt) : "", x.hasSpeed ? std::to_string(x.speedKt) : "",
               x.hasHeading ? fmt("%.0f", (double)x.headingDeg) : "", x.hasVrate ? std::to_string(x.vrateFpm) : "", x.hasPos ? fmt("%.5f", x.lat) : "", x.hasPos ? fmt("%.5f", x.lon) : "",
               x.hasRange ? fmt("%.0f", (double)x.distNm) : "", x.hasSquawk ? fmt("%04d", x.squawk) : "", x.tisb ? "TIS-B" : "ADS-B", n(x.messages), fmt("%.0f", (double)x.ageSec)});
    });
    o.table(t);

    std::vector<const UatFisbProduct*> products;
    for (const UatFisbProduct& p : a.fisb) products.push_back(&p);
    std::stable_sort(products.begin(), products.end(), [](const UatFisbProduct* x, const UatFisbProduct* y) { return x->timeSec > y->timeSec; });
    Table f("FIS-B", {"Time", "Product", "Title", "Text"});
    newestFirst(products, [&](const UatFisbProduct* p) { f.row({fmt("%.1f s", p->timeSec), n(p->productId), p->title, p->text}); });
    o.table(f);

    Table lg("Log", {"Time", "Kind", "Address", "Level", "Summary"});
    newestLast(a.framesLog, [&](const UatFrameInfo& x) {
        lg.row({fmt("%.1f s", x.timeSec), x.kind, x.address ? fmt("%06X", x.address & 0xFFFFFF) : "", db(x.levelDbfs, "dBFS"), x.summary});
    });
    o.table(lg);
}

void flarmExport(Out& o, const FlarmTelemetry& a) {
    o.card("Aircraft", n(a.aircraftCount));
    o.card("With position", n(a.withPosition));
    o.card("Packets per second", fmt("%.1f", (double)a.packetsPerSec));
    o.card("868.2 MHz", n(a.perChannel[0]));
    o.card("868.4 MHz", n(a.perChannel[1]));
    if (a.newProtocol) o.card("New protocol (counted only)", n(a.newProtocol));
    if (a.privacyFlagged) o.card("Privacy flagged (not shown)", n(a.privacyFlagged));
    if (a.maxRangeKm > 0) o.card("Max range", fmt("%.0f km", (double)a.maxRangeKm));
    o.card("Bad", n(a.blocksBad));
    o.card("Level", db(a.levelDb, "dB"));

    Table t("Aircraft", {"Id", "Type", "Alt ft", "Spd kt", "Hdg", "Climb m/s", "Lat", "Lon", "Dist km", "Level", "Heard", "Packets"});
    newestFirst(a.aircraft, [&](const FlarmAircraft& x) {
        t.row({fmt("%06X", x.id & 0xFFFFFF), flarm::aircraftTypeName(x.acType), x.hasPos ? feet(x.altM) : "", x.hasPos ? fmt("%.0f", x.speedKmh / 1.852) : "", x.hasPos ? fmt("%.0f", (double)x.trackDeg) : "",
               x.hasPos ? fmt("%+.1f", (double)x.climbMs) : "", x.hasPos ? fmt("%.5f", x.lat) : "", x.hasPos ? fmt("%.5f", x.lon) : "", x.hasRange ? fmt("%.1f", (double)x.distKm) : "",
               db(x.levelDb, "dB"), ago(x.ageSec), n(x.packets)});
    });
    o.table(t);
}

void djiExport(Out& o, const DjiTelemetry& a) {
    o.card("Drones", n(a.drones.size()));
    o.card("Signals", n(a.tracks.size()));
    o.card("DroneID packets", n(a.blocksOk));
    o.card("DroneID CRC failed", n(a.blocksBad));
    o.card("Bursts", n(a.burstsTotal));
    o.card("OFDM bursts", n(a.burstsOfdm));
    o.card("Level", db(a.levelDb, "dBFS"));
    o.card("Noise", db(a.noiseDb, "dBFS"));

    std::vector<const DjiDrone*> drones;
    for (const DjiDrone& d : a.drones) drones.push_back(&d);
    std::stable_sort(drones.begin(), drones.end(), [](const DjiDrone* x, const DjiDrone* y) { return x->lastSec > y->lastSec; });
    Table t("Drones", {"Id", "Lat", "Lon", "Alt ft", "Height m", "Pilot", "Home", "Packets", "SNR", "Last seen"});
    newestFirst(drones, [&](const DjiDrone* d) {
        const dji::DroneId& k = d->last;
        const bool fix = std::fabs(k.lat()) > 1e-4;   // the desktop's test: no GPS lock yet
        t.row({d->serial.empty() ? "no serial" : d->serial, fix ? fmt("%.6f", k.lat()) : "", fix ? fmt("%.6f", k.lon()) : "", fix ? feet(k.altitudeM()) : "", fix ? fmt("%.0f", k.heightM()) : "",
               std::fabs(k.appLat()) > 1e-4 ? latlon(k.appLat(), k.appLon()) : "", std::fabs(k.homeLat()) > 1e-4 ? latlon(k.homeLat(), k.homeLon()) : "", n(d->packets),
               db(d->snrDb, "dB"), ago(a.timeSec - d->lastSec)});
    });
    o.table(t);

    Table s("Signals", {"Class", "Conf.", "Frequency", "Width", "Burst", "Period", "Duty", "Level", "Last seen"});
    newestFirst(a.tracks, [&](const DjiTrack& k) {
        s.row({djiClassName(k.cls), fmt("%.0f %%", k.conf * 100.0), k.freqMhz > 0 ? fmt("%.1f MHz", k.freqMhz) : fmt("%+.1f MHz", k.offsetHz / 1e6), fmt("%.1f MHz", k.bwMhz) + (k.clipped ? "+" : ""),
               fmt("%.0f us", k.durUs), k.periodMs > 0 ? fmt("%.1f ms", k.periodMs) : "", fmt("%.0f %%", k.duty * 100.0), db(k.levelDb, "dBFS"), ago(a.timeSec - k.lastSec)});
    });
    o.table(s);

    static const char* const zc[4] = {"", "no", "CRC failed", "decoded"};
    Table b("Bursts", {"Time UTC", "Offset", "Width", "Length", "Level", "SNR", "OFDM", "DroneID"});
    newestFirst(a.bursts, [&](const DjiBurst& x) {
        b.row({utc(x.wallTime), fmt("%+.1f MHz", x.offsetHz / 1e6), fmt("%.1f MHz", (double)x.bwMhz), fmt("%.0f us", (double)x.durUs), db(x.levelDb, "dBFS"), db(x.snrDb, "dB"),
               fmt("%.2f", (double)x.ofdm), zc[x.zc & 3]});
    });
    o.table(b);
}

void eloran(Out& o, const ElLoranTelemetry& a) {
    o.card("State", a.state == 3 ? "locked" : a.state == 2 ? "GRI found, waiting for a second match" : a.state == 1 ? "searching for a GRI" : "no samples");
    if (a.dataValid) o.card("GRI", fmt("%d (%d us)", a.griUs / 10, a.griUs));
    if (!a.chain.empty()) o.card("Chain", a.chain);
    o.card("Master seen", yes(a.masterFound));
    o.card("Stations", n(a.stations.size()));
    if (a.dataValid) {
        o.card("Margin", db(a.snrDb, "dB"));
        o.card("Level", db(a.levelDb, "dBFS"));
        o.card("Repetition strength", fmt("%.1f", a.zScore));
    }

    Table t("Stations", {"Station", "ToA offset (us)", "Level (dBFS)", "Phase code", "Margin (dB)", "9th pulse"});
    int secondary = 0;
    newestFirst(a.stations, [&](const loran::Station& s) {
        t.row({s.master ? "master" : "secondary " + std::to_string(++secondary), fmt("%.1f", s.toaUs), fmt("%.1f", (double)s.levelDb), std::string(1, s.code), fmt("%.1f", (double)s.marginDb), yes(s.ninth)});
    });
    o.table(t);
}

void vdes(Out& o, const VdesTelemetry& a) {
    o.card("ASM frames", n(a.blocksOk));
    o.card("ASM failed", n(a.blocksBad));
    o.card("ASM 1", n(a.asmOk[0]) + " ok, " + n(a.asmBad[0]) + " bad");
    o.card("ASM 2", n(a.asmOk[1]) + " ok, " + n(a.asmBad[1]) + " bad");
    o.card("VDE-TER bursts", n(a.vdeBursts));
    o.card("Modulation", fmt("pi/4-QPSK %llu, 8PSK %llu, 16QAM %llu", (unsigned long long)a.vdeByMod[VdeModPi4Qpsk], (unsigned long long)a.vdeByMod[VdeMod8Psk], (unsigned long long)a.vdeByMod[VdeMod16Qam]));
    o.card("ASM channels in view", yes(a.asmInView));
    if (a.blocksOk) o.card("SNR", db(a.snrDb, "dB"));

    // One row per station for the map: the newest frame of each MMSI that carries a position
    Table st("Stations", {"MMSI", "Type", "Lat", "Lon", "Spd kt", "Hdg", "Ch", "Heard"});
    std::set<uint32_t> seen;
    for (const VdesAsm& m : a.asms) {
        if (!m.hasPos || !m.aisMmsi || !seen.insert(m.aisMmsi).second || seen.size() > kMaxRows) continue;
        st.row({std::to_string(m.aisMmsi), fmt("AIS %d", m.aisType), fmt("%.5f", m.lat), fmt("%.5f", m.lon), m.sogKt >= 0 ? fmt("%.1f", (double)m.sogKt) : "", m.cogDeg >= 0 ? fmt("%.0f", (double)m.cogDeg) : "",
                std::string(1, m.channel), ago(a.timeSec - m.timeSec)});
    }
    o.table(st);

    Table fr("ASM frames", {"Time UTC", "Channel", "From", "Bits", "SNR", "AIS type", "Position", "Payload"});
    newestFirst(a.asms, [&](const VdesAsm& m) {
        fr.row({utc(m.wallTime), std::string(1, m.channel), m.aisType && m.aisMmsi ? std::to_string(m.aisMmsi) : "", std::to_string(m.bits), db(m.snrDb, "dB"), m.aisType ? std::to_string(m.aisType) : "",
                m.hasPos ? latlon(m.lat, m.lon) : "", m.hex});
    });
    o.table(fr);

    Table bu("VDE-TER bursts", {"Time UTC", "MHz", "Width", "Modulation", "Level", "SNR", "Length", "Offset"});
    newestFirst(a.bursts, [&](const VdeBurst& b) {
        bu.row({utc(b.wallTime), fmt("%.3f", b.centreMhz), fmt("%d kHz", b.bwKhz), vdeModName(b.mod), db(b.rssiDb, "dBFS"), db(b.snrDb, "dB"), fmt("%.1f ms", (double)b.durMs), fmt("%+.0f Hz", (double)b.cfoHz)});
    });
    o.table(bu);
}

void marine(Out& o, const MarineTelemetry& a) {
    static const char* const service[] = {"none yet", "NAVTEX", "DSC MF/HF", "weather fax", "DSC VHF"};
    int distress = 0;
    for (const DscCall& c : a.dsc) distress += c.distress;
    o.card("State", a.state == 2 ? "decoding" : a.state == 1 ? "signal" : "searching");
    o.card("Service", a.serviceActive >= 0 && a.serviceActive <= 4 ? service[a.serviceActive] : "none yet");
    o.card("NAVTEX messages", n(a.navtexCount));
    o.card("DSC calls", n(a.dscCount));
    if (distress) o.card("Distress calls", std::to_string(distress));
    o.card("SNR", db(a.snrDb, "dB"));
    if (a.shiftHz > 0) o.card("Shift", fmt("%.0f Hz", a.shiftHz));
    if (a.baudEst > 0) o.card("Symbol rate", fmt("%.1f Bd", a.baudEst));
    if (a.fskLevelDb > 0) o.card("FSK over noise", db(a.fskLevelDb, "dB"));
    o.card("Carrier error", fmt("%+.1f Hz", a.cfoHz));
    if (a.serviceActive == 3 || a.fax.state != 0) {
        static const char* const fax[] = {"waiting for start tone", "phasing", "receiving", "stopped"};
        o.card("Fax", fax[a.fax.state & 3]);
        o.card("Fax IOC", std::to_string(a.fax.ioc));
        o.card("Fax lines per minute", std::to_string(a.fax.lpm));
        o.card("Fax lines", std::to_string(a.fax.lines));
        o.card("Fax slant", fmt("%+.1f ppm", a.fax.slantPpm));
    }

    // Both services in one log, ordered by signal time: the texter shows one table
    struct Line { double sec; std::string time, service, from, to, text; };
    std::vector<Line> lines;
    for (const NavtexMessage& m : a.navtex)
        lines.push_back({m.rxSec, utc(m.rxTime), "NAVTEX", m.header.empty() ? std::string(1, m.station) : m.header, m.subjectName, m.text});
    for (const DscCall& c : a.dsc) {
        std::string from = c.fromMmsi + (c.fromName.empty() ? "" : " " + c.fromName), to = c.to + (c.toName.empty() ? "" : " " + c.toName);
        lines.push_back({c.rxSec, utc(c.rxTime), c.vhf ? "DSC VHF" : "DSC", from, to, c.text.empty() ? (c.kind.empty() ? c.formatName : c.kind) : c.text});
    }
    std::stable_sort(lines.begin(), lines.end(), [](const Line& x, const Line& y) { return x.sec > y.sec; });
    Table m("Messages", {"Time UTC", "From", "To", "Text", "Service"});
    newestFirst(lines, [&](const Line& l) { m.row({l.time, l.from, l.to, l.text, l.service}); });
    o.table(m);

    Table d("DSC calls", {"Time UTC", "Call", "Category", "From", "To", "Position", "Check"});
    newestLast(a.dsc, [&](const DscCall& c) {
        std::string call = c.kind.empty() ? c.formatName : c.kind;
        if (!c.natureName.empty()) call += ": " + c.natureName;
        d.row({utc(c.rxTime), call, c.categoryName, c.fromMmsi, c.to, c.hasPos ? latlon(c.lat, c.lon) : "", c.eccOk ? "ok" : "bad"});
    });
    o.table(d);

    Table nv("NAVTEX", {"Time UTC", "Header", "Subject", "Characters", "Errors", "Heard", "Complete"});
    newestLast(a.navtex, [&](const NavtexMessage& x) {
        nv.row({utc(x.rxTime), x.header, x.subjectName, n(x.chars), n(x.errors), std::to_string(x.repeats), yes(x.complete)});
    });
    o.table(nv);

    Table p("DSC channels", {"Frequency", "Locked", "Calls"});
    newestFirst(a.parallel, [&](const MarineTelemetry::ParInfo& x) { p.row({fmt("%.1f kHz", x.hz / 1e3), yes(x.locked), n(x.calls)}); });
    o.table(p);
}

void marineVhf(Out& o, const MarineVhfTelemetry& a) {
    const auto region = (marinevhf::Region)a.region;
    const auto label = [](int number, char suffix) { return std::to_string(number) + (suffix ? std::string(1, suffix) : std::string()); };
    int active = 0;
    for (const MarineVhfChannelRow& r : a.rows) active += r.active;
    o.card("State", a.state == 2 ? "voice channel open" : a.state == 1 ? "listening" : "no input");
    o.card("Region", a.region >= 0 && a.region < marinevhf::kRegionCount ? marinevhf::regionName(region) : "");
    if (a.playingNumber) o.card("Playing", "ch " + label(a.playingNumber, a.playingSuffix) + fmt(", %.3f MHz", a.playingMhz));
    o.card("Channels active", std::to_string(active));
    o.card("Carriers", std::to_string(a.carriers));
    o.card("Calls", n(a.callsTotal));
    o.card("Scan", a.scanOn ? "on" : "off");
    o.card("Whole span", yes(a.spanCovers));
    if (a.recordedFiles) o.card("Recordings", std::to_string(a.recordedFiles));

    Table t("Channels", {"Ch", "MHz", "Use", "Level", "State", "Calls", "Total", "Last heard"});
    size_t rows = 0;
    for (const MarineVhfChannelRow& r : a.rows) {
        if (!(r.active || r.open || r.calls) || rows++ >= kMaxRows) continue;   // the plan has every channel: only those with something to say
        const marinevhf::Channel* c = a.region >= 0 && a.region < marinevhf::kRegionCount ? marinevhf::findChannel(region, r.number, r.suffix) : nullptr;
        t.row({label(r.number, r.suffix), fmt("%.3f", r.mhz), c ? c->name : "", db(r.levelDb, "dB"), r.open ? "voice" : r.active ? "carrier" : "quiet", std::to_string(r.calls), fmt("%.0f s", r.totalSec), ago(r.lastHeardAgoSec)});
    }
    o.table(t);

    Table lg("Calls", {"Time UTC", "Ch", "MHz", "Length", "Peak", "Mean", "Recording"});
    newestFirst(a.calls, [&](const MarineVhfCall& c) {
        const size_t slash = c.file.find_last_of("/\\");
        lg.row({utc(c.wallTime), label(c.number, c.suffix), fmt("%.3f", c.mhz), c.open ? "on air" : fmt("%.1f s", c.durationSec), db(c.peakDb, "dB"), db(c.meanDb, "dB"),
                slash == std::string::npos ? c.file : c.file.substr(slash + 1)});
    });
    o.table(lg);
}

void selcal(Out& o, const SelcalTelemetry& a) {
    o.card("State", a.state == 2 ? "call decoded" : a.state == 1 ? "audio present" : "no audio");
    o.card("Calls", n(a.blocksOk));
    o.card("Codes", n(a.codes.size()));
    if (!a.calls.empty()) o.card("Last code", a.calls.front().code);
    if (a.dialHz > 0) o.card("Frequency", fmt("%.1f kHz", a.dialHz / 1e3));
    o.card("Audio", db(a.audioDb, "dB"));
    if (a.toneHz > 0) o.card("Strongest tone", fmt("%.1f Hz", a.toneHz));

    Table t("Calls", {"Time UTC", "Code", "Tones (Hz)", "Frequency (kHz)", "dB", "Aircraft"});
    newestFirst(a.calls, [&](const SelcalCall& c) {
        t.row({utc(c.utc), c.code, fmt("%.1f %.1f %.1f %.1f", c.hz[0], c.hz[1], c.hz[2], c.hz[3]), c.dialHz > 0 ? fmt("%.1f", c.dialHz / 1e3) : "", fmt("%.0f", (double)c.levelDb), c.aircraft});
    });
    o.table(t);

    Table k("Codes", {"Code", "Aircraft", "Last heard", "Heard"});
    newestFirst(a.codes, [&](const SelcalCode& c) { k.row({c.code, c.aircraft, utc(c.lastSeen), n(c.count)}); });
    o.table(k);
}

void atis(Out& o, const AtisTelemetry& a) {
    o.card("State", a.state == 2 ? "message decoded" : a.state == 1 ? "tones seen" : "no signal");
    o.card("Messages", n(a.blocksOk));
    o.card("Failed check", n(a.blocksBad));
    o.card("Stations", n(a.stations.size()));
    if (a.otherCalls) o.card("Other DSC frames", n(a.otherCalls));
    o.card("Level", db(a.levelDb, "dBFS"));

    Table t("Messages", {"Time UTC", "ATIS number", "Country", "Call sign", "Name", "Check", "dB"});
    newestFirst(a.messages, [&](const AtisMessage& m) {
        t.row({utc(m.utc), m.digits, m.country, m.callsign, m.name, m.checkOk ? "ok" : "bad", fmt("%.0f", (double)m.levelDb)});
    });
    o.table(t);

    Table s("Stations", {"ATIS number", "Country", "Call sign", "Name", "Last heard", "Heard"});
    newestFirst(a.stations, [&](const AtisStation& x) { s.row({x.digits, x.country, x.callsign, x.name, utc(x.lastSeen), n(x.count)}); });
    o.table(s);
}

std::string satName(int sys, int prn, int fcn) {
    if (sys == GnssGlonass && prn == 0) return fmt("R (channel %+d)", fcn);   // the slot is not known yet
    return gnssSatName(sys, prn);
}
std::string healthText(int h) { return h < 0 ? "" : h == 0 ? "ok" : "bad"; }

void gnss(Out& o, const GnssTelemetry& a) {
    const GnssFix& f = a.fix;
    o.card("State", a.state == 2 ? "position fix" : a.state == 1 ? "tracking" : "searching");
    o.card("Tracked", std::to_string(a.nTracked));
    o.card("Best C/N0", db(a.snrDb, "dB-Hz"));
    if (f.valid) {
        o.card("Position", latlon(f.latDeg, f.lonDeg));
        o.card("Height", fmt("%.0f m", f.heightM));
        o.card("Solution", f.type);
        o.card("HDOP", fmt("%.1f", (double)f.hdop));
        o.card("Estimated error", fmt("%.0f m", (double)f.hErrM));
        if (f.hasVelocity) o.card("Speed", fmt("%.1f km/h, course %.0f deg", f.speedMps * 3.6, f.courseDeg));
    }
    if (f.timeValid) o.card("Satellite time", fmt("%04d-%02d-%02d %02d:%02d:%02.0f UTC", f.year, f.month, f.day, f.hour, f.minute, std::floor(f.second)));
    if (a.leapSeconds >= 0) o.card("GPS - UTC", fmt("%d s", a.leapSeconds));
    if (a.clockValid) o.card("Phone clock against satellites", fmt("%+.1f ms", a.clockOffsetAvgMs));
    o.card("Good subframes", n(a.blocksOk));
    o.card("Bad subframes", n(a.blocksBad));
    o.card("Level", db(a.levelDbfs, "dBFS"));
    if (a.clipPercent > 0) o.card("Clipping", fmt("%.2f %%", (double)a.clipPercent));
    if (a.searching) o.card("Searching", std::string(gnssSystemName(a.searchSys)) + fmt(" %02d, %.0f %%", a.searchPrn, a.searchProgress * 100.0));
    if (a.interf.valid) {
        o.card("Interference", a.interf.learning ? "learning the band" : gnssInterfStatusName(a.interf.status));
        if (!a.interf.reason.empty()) o.card("Why", a.interf.reason);
        o.card("Noise rise", db(a.interf.riseDb, "dB"));
        if (a.interf.spoofing) o.card("Spoofing", a.interf.spoofReason.empty() ? "indicated" : a.interf.spoofReason);
    }

    Table t("Channels", {"Sat", "System", "C/N0", "Doppler Hz", "Az", "El", "State", "Lock s", "Frames", "Resid m", "Health", "Fix"});
    newestFirst(a.channels, [&](const GnssChannel& c) {
        t.row({satName(c.sys, c.prn, c.fcn), gnssSystemName(c.sys), fmt("%.1f", (double)c.cn0), fmt("%.0f", c.dopplerHz), c.hasAzEl ? fmt("%.0f", (double)c.azDeg) : "", c.hasAzEl ? fmt("%.0f", (double)c.elDeg) : "",
               gnssChStateName(c.state), fmt("%.0f", (double)c.lockSecs), n(c.framesOk) + "/" + n((uint64_t)c.framesOk + c.framesBad), c.used ? fmt("%+.1f", (double)c.residualM) : "", healthText(c.health), c.used ? "yes" : ""});
    });
    o.table(t);

    Table s("Satellites", {"Id", "Name", "Lat", "Lon", "Alt km", "C/N0", "Used", "Health", "From"});
    newestFirst(a.sats, [&](const GnssSatPos& x) {
        s.row({satName(x.sys, x.prn, x.fcn), gnssSystemName(x.sys), fmt("%.3f", x.lat), fmt("%.3f", x.lon), fmt("%.0f", x.altKm), x.tracked ? fmt("%.1f", (double)x.cn0) : "", x.used ? "yes" : "", healthText(x.health),
               !x.fromEphemeris ? "almanac" : gnssEphemerisStale(x) ? "old ephemeris" : "ephemeris"});
    });
    o.table(s);

    Table k("Sky", {"Sat", "System", "Az", "El", "C/N0", "State"});
    newestFirst(a.sky, [&](const GnssSky& x) {
        k.row({satName(x.sys, x.prn, x.fcn), gnssSystemName(x.sys), fmt("%.0f", (double)x.azDeg), fmt("%.0f", (double)x.elDeg), x.tracked ? fmt("%.1f", (double)x.cn0) : "", x.used ? "in the fix" : x.tracked ? "tracked" : "not tracked"});
    });
    o.table(k);

    Table v("Navigation", {"Sat", "Ephemeris", "IODE", "Age s", "Week", "TOW s", "Clock us"});
    newestFirst(a.nav, [&](const GnssNavInfo& x) {
        const std::string ephemeris = x.hasEphemeris ? "yes" : x.ephParts > 0 ? fmt("%d of 3", x.ephParts) : "";
        v.row({satName(x.sys, x.prn, x.fcn), ephemeris, x.iode >= 0 ? std::to_string(x.iode) : "", x.hasEphemeris ? fmt("%.0f", (double)x.ephAgeS) : "", x.week >= 0 ? std::to_string(x.week) : "",
               x.towS >= 0 ? std::to_string(x.towS) : "", x.hasEphemeris ? fmt("%+.3f", (double)x.svClockBiasUs) : ""});
    });
    o.table(v);

    Table e("Interference events", {"Time UTC", "Level", "Text"});
    newestLast(a.interf.events, [&](const GnssInterfEvent& x) {
        e.row({utc((int64_t)x.unixS), x.level == 2 ? "alarm" : x.level == 1 ? "warning" : "information", x.text});
    });
    o.table(e);

    Table l("Narrowband lines", {"Line kHz", "dB", "Known"});
    newestFirst(a.interf.spikes, [&](const GnssInterfSpike& x) { l.row({fmt("%+.1f", x.offsetHz / 1e3), fmt("%.1f", (double)x.aboveDb), yes(x.known)}); });
    o.table(l);
}

void sbasExport(Out& o, const SbasTelemetry& a) {
    o.card("State", a.state == 2 ? "messages decoded" : a.state == 1 ? "tracking" : "searching");
    o.card("Satellites", n(a.sats.size()));
    o.card("Messages", n(a.total));
    o.card("Bad", n(a.blocksBad));
    o.card("Best C/N0", db(a.snrDb, "dB-Hz"));
    o.card("Level", db(a.levelDbfs, "dBFS"));
    if (a.searching) o.card("Searching", fmt("PRN %d, %.0f %%", a.searchPrn, a.searchProgress * 100.0));

    Table t("Satellites", {"PRN", "Service", "State", "C/N0", "Doppler", "Messages", "Missed", "Last type"});
    newestFirst(a.sats, [&](const SbasSat& s) {
        t.row({std::to_string(s.prn), sbasServiceOfPrn(s.prn), gnssChStateName(s.state), fmt("%.1f", (double)s.cn0), fmt("%.0f Hz", s.dopplerHz), n(s.messages), n(s.framesBad),
               s.lastType >= 0 ? std::to_string(s.lastType) : ""});
    });
    o.table(t);

    Table lg("Messages", {"Signal time", "PRN", "Type", "What it says"});
    newestLast(a.log, [&](const sbas::LogEntry& x) { lg.row({fmt("%.1f s", x.timeS), std::to_string(x.prn), std::to_string(x.type), x.text}); });
    o.table(lg);

    Table ty("Message types", {"Type", "Content", "Count"});
    for (int i = 0; i < 64; i++) if (a.typeCount[i]) ty.row({std::to_string(i), sbas::typeName(i), n(a.typeCount[i])});
    o.table(ty);

    Table fa("Fast corrections", {"PRN", "Slot", "Satellite", "Correction", "UDRE", "UDRE index", "IODF", "IODP"});
    for (const sbas::GeoState& g : a.geos)
        for (int i = 0; i < sbas::kMaxSlots && (size_t)fa.count() < kMaxRows; i++) {
            const sbas::FastCorr& c = g.fast[(size_t)i];
            if (!c.valid) continue;
            fa.row({std::to_string(g.prn), std::to_string(i + 1), sbas::Network::slotName(g, i), fmt("%+.3f m", c.prcM), sbas::udreText(c.udrei), std::to_string(c.udrei), std::to_string(c.iodf), std::to_string(c.iodp)});
        }
    o.table(fa);

    Table io("Ionosphere", {"PRN", "Band", "Grid points", "With a delay", "Not monitored", "Smallest", "Mean", "Largest", "Worst GIVE index"});
    for (const sbas::GeoState& g : a.geos)
        for (int b = 0; b < sbas::kIonoBands && (size_t)io.count() < kMaxRows; b++) {
            const sbas::IonoSummary s = sbas::Network::ionoSummary(g, b);
            if (!s.nIgp) continue;
            io.row({std::to_string(g.prn), std::to_string(b), std::to_string(s.nIgp), std::to_string(s.nValue), std::to_string(s.nNotMonitored), fmt("%.2f m", (double)s.minM), fmt("%.2f m", (double)s.meanM), fmt("%.2f m", (double)s.maxM), std::to_string(s.worstGivei)});
        }
    o.table(io);
}

void dgps(Out& o, const DgpsTelemetry& a) {
    std::string types;
    for (int x : a.typesSeen) types += (types.empty() ? "" : ", ") + std::to_string(x);
    o.card("State", a.state == 2 ? "receiving frames" : a.state == 1 ? "listening" : "no input");
    if (a.dataValid) o.card("Station", std::to_string(a.stationId));
    o.card("Bit rate", fmt("%.0f bit/s", a.bitRate));
    o.card("Frames", n(a.blocksOk));
    o.card("Complete messages", n(a.messagesComplete));
    o.card("Bad words", n(a.wordsBad));
    if (!types.empty()) o.card("Message types", types);
    if (a.dataValid) {
        o.card("Last type", std::to_string(a.lastType));
        o.card("Z-count", std::to_string(a.zcount));
        o.card("Health", std::to_string(a.health));
    }
    if (a.satellites) o.card("Satellites", std::to_string(a.satellites));
    if (a.hasPosition) { o.card("Reference position", latlon(a.lat, a.lon)); o.card("Reference height", fmt("%.1f m", a.height)); }
    if (!a.specialText.empty()) o.card("Station text", a.specialText);
    o.card("Carrier offset", fmt("%+.1f Hz", a.cfoHz));
    o.card("Level", db(a.levelDb, "dBFS"));

    Table t("Messages", {"Type", "Station", "Z-count", "Health", "Content"});
    newestFirst(a.rows, [&](const DgpsMessageRow& r) { t.row({std::to_string(r.type), std::to_string(r.station), std::to_string(r.zcount), std::to_string(r.health), r.text}); });
    o.table(t);

    Table b("Beacon almanac", {"Beacon", "Frequency", "Position", "Range", "Bit rate", "Health"});
    newestFirst(a.almanac, [&](const DgpsBeacon& x) {
        b.row({std::to_string(x.stationId), fmt("%.1f kHz", x.frequencyKhz), latlon(x.latitude, x.longitude), fmt("%d km", x.rangeKm), fmt("%d bit/s", x.bitRate), std::to_string(x.health)});
    });
    o.table(b);
}

} // namespace

// rx.standard is the active standard the engine reports (core/src/engine/engine_telemetry.cpp), one below stdMode for most of these modes.
// ASTERIX has no case: its telemetry sits on Engine::asterix(), not in RxTelemetry, and the engine never reports it.
bool aviationMarine(const RxTelemetry& rx, Out& o) {
    switch (rx.standard) {
    case 13: gnss(o, rx.gnss); return true;
    case 16: marine(o, rx.marine); return true;           // NAVTEX, DSC and weather fax share one receiver
    case 27: airband(o, rx.airband); return true;
    case 30: ndb(o, rx.ndb); return true;
    case 31: vor(o, rx.vor); return true;                 // VOR and ILS share one receiver
    case 44: uplink(o, rx.uplink); return true;
    case 57: rid(o, rx.rid); return true;
    case 64: vdes(o, rx.vdes); return true;
    case 67: flarmExport(o, rx.flarm); return true;
    case 69: djiExport(o, rx.dji); return true;
    case 83: vdl4(o, rx.vdl4); return true;
    case 84: uat(o, rx.uat); return true;
    case 121: dgps(o, rx.dgps); return true;
    case 122: dme(o, rx.dme); return true;
    case 127: eloran(o, rx.eloran); return true;
    case 143: modeAc(o, rx.modeac); return true;
    case 151: sbasExport(o, rx.sbas); return true;
    case 156: marineVhf(o, rx.marinevhf); return true;
    case 212: atis(o, rx.atis); return true;
    case 241: selcal(o, rx.selcal); return true;
    default: return false;
    }
}

} // namespace onair::results
