// What the satellite, weather and science modes show on the native screens: cards and tables with the desktop's column names, and the newest picture.
// Tables hold at most the newest kMaxRows rows, newest first. The first table with a position column is the one the map reads (TrackerPage.swift).
#include "results_kit.h"
#include "dect2/fy3/fy3_proto.h"
#include "dect2/goesdcs/goesdcs_proto.h"
#include "dect2/iono/iono_scale.h"
#include <algorithm>
#include <cmath>
#include <cstdarg>
#include <ctime>
#include <mutex>
#include <vector>

namespace onair::results {

// The newest picture of the active mode, RGBA with 4 bytes a pixel, row by row, top row first, alpha 255. false when the mode has no picture yet, or when
// the picture is still the one `seq` names: pass 0 to always get it, and keep the seq it returns (as FaxDecoder::latestImage does). Rebuilding a pass
// is many megabytes, so a caller that polls should keep seq. A picture over kMaxPicturePixels is thinned by a whole factor: w and h are what `rgba` holds.
// rgba, w, h and seq change only when it returns true.
bool latestImage(const dect2::RxTelemetry& rx, std::vector<uint8_t>& rgba, int& w, int& h, uint64_t& seq);

using namespace dect2;

namespace {

constexpr int kMaxRows = 200;
constexpr size_t kMaxText = 400;                 // bytes of one table cell of free text
constexpr int64_t kMaxPicturePixels = 8000000;   // 32 MB of RGBA; a Meteor pass is 19 Mpixel, a GOES full disk 29 Mpixel

__attribute__((format(printf, 1, 2))) std::string fmt(const char* f, ...) {
    char b[512];
    va_list ap; va_start(ap, f); vsnprintf(b, sizeof b, f, ap); va_end(ap);
    return b;
}
std::string num(uint64_t v) { return std::to_string(v); }
std::string yesNo(bool b) { return b ? "yes" : "no"; }
std::string okBad(uint64_t ok, uint64_t bad) { return num(ok) + " / " + num(bad); }
std::string hhmmss(int64_t wall) {
    if (wall <= 0) return "";
    const time_t t = (time_t)wall; struct tm tm; gmtime_r(&t, &tm);
    return fmt("%02d:%02d:%02d", tm.tm_hour, tm.tm_min, tm.tm_sec);
}
std::string dateTime(double wall) {
    const time_t t = (time_t)wall; struct tm tm; gmtime_r(&t, &tm);
    return fmt("%04d-%02d-%02d %02d:%02d:%02d UTC", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec);
}
std::string ago(double s) { return s < 90 ? fmt("%.0f s", s) : s < 5400 ? fmt("%.0f min", s / 60) : fmt("%.1f h", s / 3600); }
std::string orBlank(double v, const char* f) { return std::isnan(v) ? "" : fmt(f, v); }   // the scaled ionosphere values are NAN when not scaled
std::string timeOfDayMs(uint32_t ms) { return fmt("%02u:%02u:%02u", ms / 3600000, ms / 60000 % 60, ms / 1000 % 60); }
// a cut on a whole UTF-8 character: the JSON has to stay valid
std::string clip(const std::string& s, size_t n = kMaxText) {
    if (s.size() <= n) return s;
    while (n > 0 && ((uint8_t)s[n] & 0xC0) == 0x80) n--;
    return s.substr(0, n) + "...";
}
std::string asciiOf(const std::vector<uint8_t>& d, size_t n = 200) {
    std::string s;
    for (size_t i = 0; i < d.size() && i < n; i++) s += d[i] >= 32 && d[i] < 127 ? (char)d[i] : '.';
    return s;
}

// a list kept newest first / newest last: the newest kMaxRows, newest first
template <class V, class F> void newestFirst(const V& v, F f) { int n = 0; for (const auto& x : v) { if (n++ >= kMaxRows) break; f(x); } }
template <class V, class F> void newestLast(const V& v, F f) { int n = 0; for (auto it = v.rbegin(); it != v.rend() && n < kMaxRows; ++it, ++n) f(*it); }

void signal(Out& o, const char* state, float snr, float level, double cfo, const char* snrName = "SNR") {
    o.card("State", state);
    if (snr != 0) o.card(snrName, fmt("%.1f dB", (double)snr));
    if (level > -199) o.card("Level", fmt("%.1f dBFS", (double)level));
    o.card("Carrier offset", fmt("%+.0f Hz", cfo));
}
void eventsTable(Out& o, const std::vector<std::string>& ev) {
    Table t("Log", {"Event"});
    newestFirst(ev, [&](const std::string& e) { t.row({e}); });
    o.table(t);
}

// ---- pictures by the pass

void meteor(Out& o, const MeteorTelemetry& t) {
    static const char* const kState[] = {"searching", "carrier and symbols", "frame sync, RS failing", "decoding"};
    signal(o, kState[std::clamp(t.state, 0, 3)], t.snrDb, t.levelDb, t.cfoHz);
    o.card("Modulation", meteorModName(t.modulation));
    o.card("Symbol rate", fmt("%.1f ksym/s", t.symbolRate / 1e3));
    o.card("Carrier lock", fmt("%.0f %%", t.carrierLock * 100.0));
    o.card("Frame lock", yesNo(t.frameLock));
    o.card("Frames ok / bad", okBad(t.blocksOk, t.blocksBad));
    o.card("RS corrected", num(t.rsCorrected));
    o.card("Packets", num(t.packets));
    o.card("Packets lost", num(t.packetsLost));
    if (t.image) o.card("Picture lines", std::to_string(t.image->rows * 8));
    if (t.scid >= 0) o.card("Spacecraft", std::to_string(t.scid));
    if (t.onboardMs) o.card("Onboard time (Moscow)", timeOfDayMs(t.onboardMs));
    Table c("Channels", {"Channel", "Packets"});
    for (int i = 0; i < 6; i++) c.row({fmt("Channel %d (APID %d)", i + 1, 64 + i), num(t.apidPackets[i])});
    c.row({"Telemetry (APID 70)", num(t.apidPackets[6])});
    c.row({"Other", num(t.apidPackets[7])});
    o.table(c);
}

void hrpt(Out& o, const HrptTelemetry& t) {
    static const char* const kState[] = {"searching", "carrier and symbols", "frame sync, frames failing", "decoding"};
    signal(o, kState[std::clamp(t.state, 0, 3)], t.snrDb, t.levelDb, t.cfoHz);
    o.card("Satellite type", hrptVarName(t.variant));
    o.card("Symbol rate", fmt("%.2f Msym/s", t.symbolRate / 1e6));
    o.card("Carrier lock", fmt("%.0f %%", t.carrierLock * 100.0));
    o.card("Frame lock", yesNo(t.frameLock));
    o.card("Frames ok / bad", okBad(t.blocksOk, t.blocksBad));
    o.card("AVHRR lines", num(t.lines));
    if (t.variant != 3) o.card("Packets lost", num(t.packetsLost));
    if (t.scid >= 0) o.card("Spacecraft", std::to_string(t.scid));
    if (t.onboardMs) o.card("Onboard time", timeOfDayMs(t.onboardMs));
    Table c("Packets", {"Packets", "Count"});
    c.row({"AVHRR with 3A (APID 103)", num(t.apidPackets[0])});
    c.row({"AVHRR with 3B (APID 104)", num(t.apidPackets[1])});
    c.row({"NOAA minor frames", num(t.apidPackets[2])});
    c.row({"Other", num(t.apidPackets[3])});
    o.table(c);
}

void fy3(Out& o, const Fy3Telemetry& t) {
    static const char* const kState[] = {"searching", "carrier and symbols", "frame sync, frames failing", "decoding"};
    static const char* const kSat[8] = {"FY-3A", "FY-3B", "FY-3C", "FY-3D", "FY-3E", "FY-3F", "FY-3G", "FY-3H"};
    signal(o, kState[std::clamp(t.state, 0, 3)], t.snrDb, t.levelDb, t.cfoHz, "Es/N0");
    o.card("Product", t.product ? "MPT" : "AHRPT");
    if (t.sat >= 0 && t.sat < 8) o.card("Satellite", kSat[t.sat]);
    o.card("Symbol rate", fmt("%.2f Msym/s", t.symbolRate / 1e6));
    o.card("Code lock", yesNo(t.railLock));
    o.card("Frame lock", yesNo(t.frameLock));
    o.card("Frames ok / bad", okBad(t.blocksOk, t.blocksBad));
    o.card("Bit error rate", fmt("%.4f", (double)t.viterbiBer));
    o.card("Picture rows", num(t.lines));
    if (t.onboardMs) o.card("Onboard time", timeOfDayMs(t.onboardMs));
    if (!t.hint.empty()) o.card("Hint", t.hint);
    Table c("Instruments", {"Instrument", "Frames", "Rows / packets"});
    newestFirst(t.inst, [&](const Fy3InstStat& i) { c.row({fy3::instName(i.inst), num(i.frames), num(i.units)}); });
    o.table(c);
}

// ---- geostationary xRIT: the receiver side is the same, GK-2A and FengYun add to it

void hritLink(Out& o, const GoesTelemetry& t) {
    static const char* const kState[] = {"searching", "carrier and symbols", "frames found", "decoding"};
    signal(o, kState[std::clamp(t.state, 0, 3)], t.snrDb, t.levelDb, t.cfoHz, "Es/N0");
    o.card("Symbol rate", t.symbolRate >= 1e6 ? fmt("%.3f Msym/s", t.symbolRate / 1e6) : fmt("%.1f ksym/s", t.symbolRate / 1e3));
    o.card("Carrier lock", yesNo(t.carrierLock));
    o.card("Frame lock", yesNo(t.frameLock));
    o.card("Frames ok / bad", okBad(t.blocksOk, t.blocksBad));
    o.card("RS corrected", num(t.rsCorrected));
    o.card("VCDUs", num(t.vcdus));
    o.card("Packets", num(t.packets));
    o.card("CRC errors", num(t.crcErrors));
    o.card("Files / with errors", okBad(t.files, t.fileErrors));
    o.card("Products", std::to_string(t.products.size()));
    if (t.scid >= 0) o.card("Spacecraft", std::to_string(t.scid));
}
void hritTables(Out& o, const GoesTelemetry& t) {
    Table p("Products", {"Product", "Kind", "Done", "Text"});
    newestFirst(t.products, [&](const std::shared_ptr<goes::Product>& x) {
        if (!x) return;
        std::string done, text;
        {
            std::lock_guard<std::mutex> lk(x->mu);   // the decoder thread is still adding to it
            if (x->w > 0 && x->h > 0) done = fmt("%d%%%s", x->rowsDone * 100 / x->h, x->errors ? " !" : "");
            else done = !x->complete ? "..." : x->errors ? "errors" : x->bytes >= 10240 ? fmt("%llu kB", (unsigned long long)x->bytes / 1024) : fmt("%llu B", (unsigned long long)x->bytes);
            text = x->note.empty() ? clip(x->text) : x->note;
        }
        p.row({x->name, goes::kindName(x->kind), done, text});
    });
    o.table(p);
    eventsTable(o, t.log);
}

void gk2a(Out& o, const Gk2aTelemetry& t) {
    o.card("Link", gk2aLinkName(t.link));
    hritLink(o, t);
    o.card("Keys loaded", std::to_string(t.keysLoaded));
    if (t.segmentsLocked > 0) o.card("Segments waiting for a key", std::to_string(t.segmentsLocked));
    if (!t.hint.empty()) o.card("Hint", t.hint);
    hritTables(o, t);
}

void fygeo(Out& o, const FygeoTelemetry& t) {
    o.card("Link", fygeoLinkName(t.link));
    hritLink(o, t);
    if (!t.signalInfo.empty()) o.card("Signal", t.signalInfo);
    if (fygeoIsS2(t.link)) {
        o.card("DVB-S2 frame / FEC / TS", yesNo(t.s2Frame) + " / " + yesNo(t.s2Fec) + " / " + yesNo(t.s2Ts));
        if (t.s2Modcod >= 0) o.card("MODCOD", t.s2Modulation + " " + t.s2CodeRate);
        o.card("MER", fmt("%.1f dB", (double)t.s2MerDb));
        o.card("CADUs", num(t.caduCount));
        o.card("TS packets / errors", okBad(t.tsPackets, t.tsErrors));
        o.card("Image segments", num(t.imageSegments));
        o.card("Pictures done", num(t.imagesDone));
        o.card("Encrypted files", num(t.encryptedFiles));
    } else {
        o.card("Scan lines", num(t.svFrames));
        o.card("Usable lines", num(t.svUsable));
        if (t.svLine >= 0) o.card("Line", std::to_string(t.svLine));
        if (t.svPreambleBer >= 0) o.card("Bit error ratio", fmt("%.1e", t.svPreambleBer));
        o.card("Pictures started", std::to_string(t.svImages));
    }
    if (!t.hint.empty()) o.card("Hint", t.hint);
    hritTables(o, t);
}

void elektro(Out& o, const ElektroTelemetry& t) {
    o.card("Satellite", fmt("%s, %s", elektroCraftName(t.craft), elektroCraftPos(t.craft)));
    o.card("Link", elektroLinkName(t.link));
    if (!elektroIsGgak(t.link)) { hritLink(o, t.hrit); hritTables(o, t.hrit); return; }
    const GgakTelemetry& g = t.ggak;
    static const char* const kState[] = {"searching", "carrier", "frames"};
    signal(o, kState[std::clamp(g.state, 0, 2)], g.snrDb, g.levelDb, g.cfoHz, "Es/N0");
    o.card("Frames ok / bad", okBad(g.blocksOk, g.blocksBad));
    if (g.lastMarker >= 0) o.card("Last marker / sub", fmt("%d / %d", g.lastMarker, g.lastSub));
    if (g.magOk) o.card("Magnetic field (unverified)", fmt("%.1f nT", (double)g.bmag));
    Table f("Frames", {"Marker", "Sub", "Timestamp", "CRC", "B (nT)"});
    newestFirst(g.frames, [&](const GgakFrame& x) {
        f.row({std::to_string(x.marker), std::to_string(x.sub), num(x.timestamp), x.crcOk ? "ok" : "bad",
               x.magOk ? fmt("%.1f, %.1f, %.1f", (double)x.bx, (double)x.by, (double)x.bz) : ""});
    });
    o.table(f);
    eventsTable(o, g.log);
}

// ---- beacons and platforms

void sarsat(Out& o, const SarsatTelemetry& t) {
    static const char* const kState[] = {"no input", "listening", "beacon heard"};
    signal(o, kState[std::clamp(t.state, 0, 2)], t.snrDb, t.levelDb, t.cfoHz);
    o.card("Bursts heard", num(t.bursts));
    o.card("Decoded / failed", okBad(t.blocksOk, t.blocksBad));
    const auto position = [](const sarsat::Beacon& b) { return b.hasPos ? fmt("%.4f, %.4f", b.lat, b.lon) : std::string(); };
    const auto kind = [](const sarsat::Beacon& b) { return (b.selfTest ? "self test " : "") + b.beaconType; };
    // one row a beacon for the map, with the newest position it sent: a beacon repeats about every 50 s
    Table beacons("Beacons", {"Id", "Type", "Country", "Position", "Identification", "Heard", "Homing"});
    std::vector<std::string> seen;
    for (const SarsatEntry& e : t.log) {
        if ((int)seen.size() >= kMaxRows) break;
        if (std::find(seen.begin(), seen.end(), e.b.hexId) != seen.end()) continue;
        seen.push_back(e.b.hexId);
        std::string pos = position(e.b);
        for (const SarsatEntry& older : t.log) if (pos.empty() && older.b.hexId == e.b.hexId) pos = position(older.b);
        beacons.row({e.b.hexId, kind(e.b), e.b.country, pos, e.b.idText, hhmmss(e.wallTime), yesNo(e.b.homing)});
    }
    o.table(beacons);
    Table log("Bursts", {"Seen", "Hex ID", "Type", "Country", "Position", "Checks", "Level"});
    newestFirst(t.log, [&](const SarsatEntry& e) {
        log.row({hhmmss(e.wallTime), e.b.hexId, kind(e.b), e.b.country, position(e.b), e.b.bch2Present ? (e.b.bch2Ok ? "1 + 2" : "1") : "1", fmt("%.0f dB", (double)e.snrDb)});
    });
    o.table(log);
}

void argos(Out& o, const ArgosTelemetry& t) {
    static const char* const kState[] = {"no input", "listening", "decoded"};
    signal(o, kState[std::clamp(t.state, 0, 2)], t.snrDb, t.levelDb, t.cfoHz);
    o.card("Link", t.link ? "downlink, 465.9875 MHz" : "uplink, 401.65 MHz");
    o.card("Decoded / other", okBad(t.blocksOk, t.blocksBad));
    if (t.link == 0) {
        o.card("Bursts", num(t.bursts));
        o.card("Not PTT-A2", num(t.otherBursts));
        o.card("Platforms", std::to_string(t.ptts.size()));
    } else {
        o.card("Carrier", t.dlLocked ? fmt("%+.0f Hz, %.0f dB", t.dlCarrierHz, (double)t.dlCnrDb) : "searching");
        o.card("Bits", num(t.dlBits));
        o.card("Bad FCS", num(t.dlFcsBad));
    }
    Table b("Bursts", {"Seen", "Format", "Platform ID", "Data", "Offset", "Level", "SNR"});
    newestFirst(t.log, [&](const ArgosBurst& e) {
        b.row({hhmmss(e.wallTime), e.kind == 1 ? "PTT-A2" : "other", e.msg.idHex, e.kind == 1 ? clip(argos::hexOf(e.msg.data)) : "",
               fmt("%+.0f Hz", e.carrierHz), fmt("%.0f dBFS", (double)e.levelDb), fmt("%.1f dB", (double)e.snrDb)});
    });
    o.table(b);
    Table p("Platforms", {"Platform ID", "Bursts", "Last", "Drift", "Last data"});
    newestFirst(t.ptts, [&](const ArgosPtt& x) {
        p.row({x.idHex, std::to_string(x.count), hhmmss(x.lastWall), fmt("%+.1f Hz/min", x.driftHzPerMin), clip(x.lastData)});
    });
    o.table(p);
    Table f("Downlink frames", {"Seen", "Bytes", "FCS", "Frame"});
    newestFirst(t.frames, [&](const ArgosDlFrame& x) { f.row({hhmmss(x.wallTime), std::to_string(x.bytes), x.fcsOk ? "ok" : "bad", clip(x.hex)}); });
    o.table(f);
}

void orbcomm(Out& o, const OrbcommTelemetry& t) {
    static const char* const kState[] = {"searching", "carrier found", "decoding"};
    signal(o, kState[std::clamp(t.state, 0, 2)], t.snrDb, -200, t.cfoHz, "Es/N0");
    o.card("Packets ok / bad", okBad(t.blocksOk, t.blocksBad));
    o.card("Messages", num(t.messages));
    o.card("Satellites", std::to_string(t.sats.size()));
    if (!t.note.empty()) o.card("Note", t.note);
    Table s("Satellites", {"Id", "Lat", "Lon", "Alt km", "Heard", "Doppler", "MHz", "Es/N0", "Packets", "Bad"});
    newestFirst(t.sats, [&](const OrbcommSat& x) {
        s.row({std::to_string(x.id), x.hasPos ? fmt("%.4f", x.lat) : "", x.hasPos ? fmt("%.4f", x.lon) : "", x.hasPos ? fmt("%.0f", x.altKm) : "",
               ago(std::max(0.0, t.timeSec - x.lastHeard)), fmt("%+.0f Hz", x.dopplerHz), fmt("%.4f", x.freqHz / 1e6), fmt("%.1f dB", (double)x.snrDb), num(x.packets), num(x.bad)});
    });
    o.table(s);
    Table c("Downlinks", {"Decoder", "State", "MHz", "Sat", "Doppler", "SNR", "Packets ok", "Packets bad"});
    static const char* const kChan[] = {"free", "acquiring", "tracking", "frame lock"};
    for (int i = 0; i < kOrbcommChannels; i++) {
        const OrbcommChannel& x = t.ch[i];
        if (!x.active) continue;
        c.row({std::to_string(i), kChan[std::clamp(x.state, 0, 3)], fmt("%.4f", x.freqHz / 1e6), x.sat >= 0 ? std::to_string(x.sat) : "", fmt("%+.0f Hz", x.dopplerHz),
               fmt("%.1f dB", (double)x.snrDb), num(x.pktOk), num(x.pktBad)});
    }
    o.table(c);
    static const char* const kType[orbcomm::kTypeSlots] = {"Sync", "Message", "Uplink", "Downlink", "Ephemeris", "Elements", "Network", "Fill", "Other"};
    Table l("Packets", {"Time s", "From", "Type", "Text"});
    newestLast(t.log, [&](const OrbcommPacket& x) {
        l.row({fmt("%.1f", x.time), x.sat >= 0 ? fmt("Sat %d", x.sat) : "", kType[std::clamp(x.type, 0, orbcomm::kTypeSlots - 1)], clip(x.text)});
    });
    o.table(l);
}

void goesDcs(Out& o, const DcsTelemetry& t) {
    static const char* const kState[] = {"nothing heard", "carriers seen", "reports decoded"};
    signal(o, kState[std::clamp(t.state, 0, 2)], t.snrDb, -200, t.cfoHz);
    o.card("Reports / cut off or bad", okBad(t.blocksOk, t.blocksBad));
    o.card("Platforms", std::to_string(t.platforms.size()));
    o.card("Carriers followed", std::to_string(t.carriers.size()));
    o.card("Carriers seen", num(t.carriersSeen));
    Table m("Reports", {"Time UTC", "From", "Channel", "Rate", "Level", "Text"});
    newestFirst(t.messages, [&](const DcsMessage& x) {
        m.row({hhmmss(x.wallTime), dcs::addressHex(x.address), x.channel ? std::to_string(x.channel) : "", fmt("%d bps", x.bps), fmt("%.0f dB", (double)x.snrDb), clip(x.text)});
    });
    o.table(m);
    Table p("Platforms", {"Platform", "Reports", "Last (UTC)", "Channel", "Rate", "Level", "Latest data"});
    newestFirst(t.platforms, [&](const DcsPlatform& x) {
        p.row({dcs::addressHex(x.address), std::to_string(x.count), hhmmss(x.lastTime), x.channel ? std::to_string(x.channel) : "", fmt("%d bps", x.bps), fmt("%.0f dB", (double)x.snrDb), clip(x.last)});
    });
    o.table(p);
}

// ---- frames from amateur satellites

void cubesat(Out& o, const CubeTelemetry& t) {
    static const char* const kState[] = {"no signal", "carrier", "frames decoded"};
    signal(o, kState[std::clamp(t.state, 0, 2)], t.snrDb, t.levelDb, t.cfoHz);
    o.card("Frames ok / failed", okBad(t.blocksOk, t.blocksBad));
    o.card("Fixed by Reed-Solomon", num(t.rsFixed));
    if (!t.tracked.empty()) o.card("Pass of", t.tracked);
    for (int i = 0; i < cubesat::kNumFramings; i++) if (t.perFraming[i]) o.card(cubesat::framingName(i), num(t.perFraming[i]));
    Table f("Frames", {"Time UTC", "From", "To", "Satellite", "Framing", "Bytes", "Text"});
    newestFirst(t.frames, [&](const CubeFrame& x) {
        f.row({hhmmss(x.wallTime), !x.from.empty() ? x.from : x.hasCsp ? fmt("CSP %d", x.csp.src) : "", !x.to.empty() ? x.to : x.hasCsp ? fmt("CSP %d", x.csp.dst) : "",
               x.sat, cubesat::framingShort(x.framing), std::to_string(x.data.size()), asciiOf(x.payload)});
    });
    o.table(f);
}

void loraSat(Out& o, const LoraSatTelemetry& t) {
    signal(o, t.state ? "frames heard" : "nothing heard", t.snrDb, t.levelDb, t.cfoHz);
    o.card("Frames ok / CRC errors", okBad(t.blocksOk, t.blocksBad));
    o.card("Preambles", num(t.preambles));
    o.card("Bad headers", num(t.headerBad));
    o.card("Doppler allowance", fmt("+-%.1f kHz", t.dopplerMaxHz / 1e3));
    if (!t.tracked.empty()) o.card("Pass of", t.tracked);
    Table f("Frames", {"Time UTC", "From", "MHz", "SF", "BW kHz", "CRC", "Bytes", "SNR dB", "Doppler Hz", "Rate Hz/s", "Text", "Hex"});
    newestFirst(t.log, [&](const LsFrame& x) {
        f.row({hhmmss(x.wallTime), x.sat, fmt("%.4f", x.freqHz / 1e6), std::to_string(x.sf), fmt("%.1f", x.bwHz / 1e3), !x.hasCrc ? "none" : x.crcOk ? "ok" : "bad", std::to_string(x.len),
               fmt("%.1f", (double)x.snrDb), fmt("%+.0f", x.cfoHz), fmt("%+.1f", x.rateHzS), clip(x.ascii), clip(x.hex)});
    });
    o.table(f);
    Table d("Demodulators", {"SF", "BW kHz", "Sync", "In band", "Preambles", "Frames", "CRC bad"});
    newestFirst(t.decoders, [&](const LsDecoderInfo& x) {
        d.row({std::to_string(x.sf), fmt("%.1f", x.bwHz / 1e3), fmt("0x%02X", x.sync), yesNo(x.inBand), num(x.preambles), num(x.frames), num(x.crcBad)});
    });
    o.table(d);
}

void globalstar(Out& o, const GlobalstarTelemetry& t) {
    static const char* const kState[] = {"nothing heard", "activity seen lately", "active now"};
    signal(o, kState[std::clamp(t.state, 0, 2)], t.snrDb, -200, t.cfoHz);
    o.card("Channels active", std::to_string(t.activeNow));
    o.card("Activity events", num(t.blocksOk));
    Table c("Channels", {"Ch", "MHz", "Power", "SNR", "Occupancy", "Doppler", "Events"});
    newestFirst(t.chan, [&](const GsChannel& x) {
        if (!x.inView) return;
        c.row({std::to_string(x.index + 1), fmt("%.2f", x.centreMhz), fmt("%.1f dBFS", (double)x.powerDb), fmt("%.1f dB", (double)x.snrDb), fmt("%.0f %%", x.occupancy * 100.0),
               x.active ? fmt("%+.0f Hz", x.dopplerHz) : "", std::to_string(x.events)});
    });
    o.table(c);
    Table e("Events", {"Time", "Channel", "MHz", "Duration", "Peak SNR", "Doppler start to end"});
    newestFirst(t.events, [&](const GsEvent& x) {
        e.row({x.wallTime ? hhmmss(x.wallTime) : fmt("%.0f s", x.startSec), std::to_string(x.chan + 1), fmt("%.2f", globalstarChannelHz(x.chan) / 1e6), fmt("%.1f s", x.durationSec),
               fmt("%.1f dB", (double)x.peakSnrDb), fmt("%+.0f to %+.0f Hz", (double)x.dopplerStartHz, (double)x.dopplerEndHz)});
    });
    o.table(e);
}

void qo100(Out& o, const Qo100Telemetry& t) {
    static const char* const kState[] = {"waiting for the transponder", "searching for the beacons", "locked", "held (beacons lost)"};
    o.card("State", kState[std::clamp(t.state, 0, 3)]);
    if (t.corrValid) o.card("LNB error", fmt("%+.0f Hz (%+.2f ppm)%s", t.lnbErrHz, t.lnbErrPpm, t.corrApplied ? "" : ", not applied"));
    if (t.driftValid) o.card("LNB drift", fmt("%+.1f Hz/min", t.driftHzPerMin));
    o.card("Narrowband transponder", t.nbOk ? "in band" : "out of band");
    o.card("Wideband transponder", t.wbOk ? "in band" : "out of band");
    int found = 0;
    for (const Qo100Beacon& b : t.beacons) found += b.found;
    o.card("Beacons found", fmt("%d of 3", found));
    o.card("Input power", fmt("%.1f dBFS", t.powerDb));
    if (t.listening) { o.card("Dial", fmt("%.4f MHz", t.dialHz / 1e6)); o.card("Audio", fmt("%.1f dB", (double)t.audioDb)); }
    const Qo100AutoTelemetry& a = t.autoDec;
    o.card("Decodes", num(a.decodeTotal));
    if (!a.images.empty()) o.card("SSTV pictures", std::to_string(a.images.size()));
    Table m("Decodes", {"Time UTC", "From", "Mode", "Downlink MHz", "dB", "Text"});
    newestLast(a.decodes, [&](const Qo100Decode& x) {
        m.row({hhmmss((int64_t)x.utc), x.call, qo100DecoderName(x.kind), fmt("%.4f", x.rfHz / 1e6), fmt("%.0f", (double)x.snrDb), x.text});
    });
    o.table(m);
    Table s("Signals", {"Downlink MHz", "Width", "dB", "Type", "Decoding"});
    newestFirst(a.tracks, [&](const Qo100Track& x) {
        std::string dec;
        for (int bit = 1; bit <= kQoDecRtty; bit <<= 1) if (x.decMask & bit) dec += (dec.empty() ? "" : ", ") + std::string(qo100DecoderName(bit));
        s.row({fmt("%.4f", x.rfHz / 1e6), fmt("%.0f Hz", x.widthHz), fmt("%.0f", (double)x.snrDb), x.idName.empty() ? qo100ClassName(x.cls) : x.idName, dec});
    });
    o.table(s);
    Table k("Keyboard", {"Mode", "Downlink MHz", "dB", "Text"});
    newestFirst(a.texts, [&](const Qo100Text& x) { k.row({qo100DecoderName(x.kind), fmt("%.4f", x.rfHz / 1e6), fmt("%.0f", (double)x.snrDb), clip(x.text)}); });
    o.table(k);
    Table c("Conversations", {"Start (UTC)", "Length", "Dial MHz", "dB", "Drift", "Stations", "Heard"});
    newestFirst(a.convs, [&](const Qo100Conversation& x) {
        std::string calls;
        for (const std::string& n : x.calls) calls += (calls.empty() ? "" : ", ") + n;
        c.row({hhmmss((int64_t)x.startUtc), fmt("%.0f s", x.lastUtc - x.startUtc), fmt("%.4f", x.dialHz / 1e6), fmt("%.0f", (double)x.levelDb), x.driftValid ? fmt("%+.1f Hz/min", x.driftHzPerMin) : "",
               std::to_string(x.stations), calls});
    });
    o.table(c);
    Table d("DATV", {"Downlink", "Symbol rate", "SNR"});
    newestFirst(t.datv, [&](const Qo100Datv& x) {
        d.row({fmt("%.3f MHz%s", x.rfHz / 1e6, x.beacon ? " (beacon)" : ""), x.symRate > 0 ? fmt("%.0f ksym/s", x.symRate / 1e3) : "", fmt("%.1f dB", (double)x.snrDb)});
    });
    o.table(d);
}

void ssdv(Out& o, const SsdvTelemetry& t) {
    static const char* const kState[] = {"no signal", "carrier", "packets"};
    signal(o, kState[std::clamp(t.state, 0, 2)], t.snrDb, t.levelDb, t.cfoHz);
    o.card("Packets ok / bad", okBad(t.blocksOk, t.blocksBad));
    o.card("Corrected", num(t.corrected));
    o.card("Pictures done", num(t.imagesDone));
    if (t.baud) o.card("Baud", fmt("%d%s", t.baud, t.wenet ? " Wenet" : t.async ? " 8N2" : ""));
    Table p("Pictures", {"Picture", "Size", "Packets", "Missing", "Complete", "Last"});
    newestFirst(t.images, [&](const SsdvImage& x) {
        p.row({x.call + fmt(" #%d", x.imageId), fmt("%d x %d", x.width, x.height), std::to_string(x.packets), std::to_string(x.missing), yesNo(x.complete), hhmmss(x.lastUtc)});
    });
    o.table(p);
    Table k("Packets", {"UTC", "Call", "Picture", "Packet", "Baud", "Fixed", "Detail"});
    newestFirst(t.packets, [&](const SsdvPacketLog& x) {
        k.row({hhmmss(x.utc), x.call, std::to_string(x.imageId), fmt("%d%s", x.packetId, x.eoi ? " end" : ""), fmt("%d%s", x.baud, x.wenet ? " Wenet" : x.async ? " 8N2" : ""),
               x.rsErrors > 0 ? std::to_string(x.rsErrors) : "", std::string(x.noFec ? "no FEC " : "") + (x.inverted ? "swapped" : "")});
    });
    o.table(k);
}

// ---- weather balloons

void sonde(Out& o, const SondeTelemetry& t) {
    static const char* const kState[] = {"searching", "signal", "decoding"};
    signal(o, kState[std::clamp(t.state, 0, 2)], t.snrDb, -200, t.cfoHz);
    int active = 0;
    for (const SondeInfo& s : t.sondes) active += s.active;
    o.card("Sondes heard", std::to_string(t.sondes.size()));
    o.card("Active now", std::to_string(active));
    o.card("Frames ok / bad", okBad(t.blocksOk, t.blocksBad));
    o.card("Channels", fmt("%d of %d", t.channelsUsed, t.channelsMax));
    Table p("Sondes", {"Name", "Type", "Lat", "Lon", "Alt ft", "Spd kt", "Hdg", "Alt m", "MHz", "V m/s", "Temp", "Sats", "SNR dB", "Frames", "Heard", "Note"});
    newestFirst(t.sondes, [&](const SondeInfo& s) {
        p.row({s.serial.empty() ? s.type : s.serial, s.subtype.empty() ? s.type : s.subtype,
               s.hasPos ? fmt("%.5f", s.lat) : "", s.hasPos ? fmt("%.5f", s.lon) : "", s.hasPos ? fmt("%.0f", s.altM * 3.28084) : "",
               s.hasVel ? fmt("%.0f", s.hSpeed * 1.94384) : "", s.hasVel ? fmt("%.0f", s.headingDeg) : "", s.hasPos ? fmt("%.0f", s.altM) : "",
               s.freqHz > 0 ? fmt("%.3f", s.freqHz / 1e6) : "", s.hasVel ? fmt("%+.1f", s.vSpeed) : "", s.hasTemp ? fmt("%.1f", s.tempC) : "", s.sats >= 0 ? std::to_string(s.sats) : "",
               fmt("%.1f", (double)s.snrDb), num(s.framesOk), ago(s.lastHeardS), s.note});
    });
    o.table(p);
    Table c("Carriers", {"Frequency", "Level dB", "Channel", "Sonde"});
    newestFirst(t.carriers, [&](const SondeCarrier& x) {
        std::string who;
        if (x.channel >= 0) for (const SondeInfo& s : t.sondes) if (s.channel == x.channel) who = s.serial;
        c.row({x.freqHz > 0 ? fmt("%.3f MHz", x.freqHz / 1e6) : fmt("%+.1f kHz", x.offsetHz / 1e3), fmt("%.0f", (double)x.levelDb), x.assigned ? std::to_string(x.channel) : "", who});
    });
    o.table(c);
}

// ---- navigation

void gnss(Out& o, const GnssTelemetry& t) {
    static const char* const kState[] = {"searching", "satellites tracked", "position fix"};
    o.card("State", kState[std::clamp(t.state, 0, 2)]);
    o.card("Tracked", std::to_string(t.nTracked));
    if (t.snrDb != 0) o.card("Best C/N0", fmt("%.1f dB-Hz", (double)t.snrDb));
    o.card("Level", fmt("%.1f dBFS", (double)t.levelDbfs));
    o.card("Subframes ok / bad", okBad(t.blocksOk, t.blocksBad));
    const GnssFix& f = t.fix;
    if (f.valid) {
        o.card("Position", fmt("%.6f, %.6f", f.latDeg, f.lonDeg));
        o.card("Height", fmt("%.0f m", f.heightM));
        o.card("Solution", f.type);
        o.card("Satellites used", std::to_string(f.nSats));
        o.card("HDOP", fmt("%.1f", (double)f.hdop));
        o.card("Horizontal error", fmt("%.0f m", (double)f.hErrM));
        if (f.hasVelocity) o.card("Speed", fmt("%.1f m/s, %.0f deg", f.speedMps, f.courseDeg));
        if (f.timeValid) o.card("UTC", fmt("%04d-%02d-%02d %02d:%02d:%02.0f", f.year, f.month, f.day, f.hour, f.minute, f.second));
    }
    if (t.leapSeconds >= 0) o.card("Leap seconds", std::to_string(t.leapSeconds));
    if (t.clockValid) o.card("Computer clock", fmt("%+.1f ms", t.clockOffsetAvgMs));
    // the satellites' sub-points; a GLONASS satellite whose slot is not known yet has no name of its own
    Table s("Satellite positions", {"Name", "Type", "Lat", "Lon", "Alt km", "Tracked", "Used", "C/N0"});
    newestFirst(t.sats, [&](const GnssSatPos& x) {
        if (x.sys == GnssGlonass && x.prn == 0) return;
        s.row({gnssSatName(x.sys, x.prn), gnssSystemName(x.sys), fmt("%.3f", x.lat), fmt("%.3f", x.lon), fmt("%.0f", x.altKm), yesNo(x.tracked), yesNo(x.used), x.cn0 > 0 ? fmt("%.0f", (double)x.cn0) : ""});
    });
    o.table(s);
    Table c("Channels", {"Sat", "System", "C/N0", "Doppler Hz", "Az", "El", "State", "Lock s", "Frames", "Health"});
    newestFirst(t.channels, [&](const GnssChannel& x) {
        c.row({gnssSatName(x.sys, x.prn), gnssSystemName(x.sys), fmt("%.1f", (double)x.cn0), fmt("%+.0f", x.dopplerHz), x.hasAzEl ? fmt("%.0f", (double)x.azDeg) : "", x.hasAzEl ? fmt("%.0f", (double)x.elDeg) : "",
               gnssChStateName(x.state), fmt("%.0f", (double)x.lockSecs), std::to_string(x.framesOk), x.health < 0 ? "" : x.health ? "unhealthy" : "ok"});
    });
    o.table(c);
}

void dgps(Out& o, const DgpsTelemetry& t) {
    static const char* const kState[] = {"no input", "listening", "frames"};
    signal(o, kState[std::clamp(t.state, 0, 2)], 0, t.levelDb, t.cfoHz);
    if (t.stationId) o.card("Station", std::to_string(t.stationId));
    o.card("Bit rate", fmt("%.0f bit/s", t.bitRate));
    o.card("Frames", num(t.blocksOk));
    o.card("Messages complete", num(t.messagesComplete));
    o.card("Words failed", num(t.wordsBad));
    o.card("Satellites", std::to_string(t.satellites));
    if (t.hasPosition) o.card("Reference station", fmt("%.5f, %.5f, %.0f m", t.lat, t.lon, t.height));
    if (!t.specialText.empty()) o.card("Station text", t.specialText);
    Table b("Beacons", {"Id", "Frequency", "Position", "Range", "Bit rate", "Health"});
    newestFirst(t.almanac, [&](const DgpsBeacon& x) {
        b.row({std::to_string(x.stationId), fmt("%.1f kHz", x.frequencyKhz), fmt("%.4f, %.4f", x.latitude, x.longitude), fmt("%d km", x.rangeKm), std::to_string(x.bitRate), std::to_string(x.health)});
    });
    o.table(b);
    Table m("Messages", {"Type", "Station", "Z-count", "Health", "Content"});
    newestFirst(t.rows, [&](const DgpsMessageRow& x) {
        m.row({std::to_string(x.type), std::to_string(x.station), std::to_string(x.zcount), std::to_string(x.health), clip(x.text)});
    });
    o.table(m);
}

void sbas(Out& o, const SbasTelemetry& t) {
    static const char* const kState[] = {"searching", "satellites tracked", "messages decoded"};
    signal(o, kState[std::clamp(t.state, 0, 2)], 0, t.levelDbfs, t.cfoHz);
    if (t.snrDb != 0) o.card("Best C/N0", fmt("%.1f dB-Hz", (double)t.snrDb));
    o.card("Messages ok / bad", okBad(t.blocksOk, t.blocksBad));
    o.card("Satellites", std::to_string(t.sats.size()));
    if (!t.status.empty()) o.card("Status", t.status);
    Table s("Satellites", {"PRN", "State", "C/N0", "Doppler", "Messages", "Missed", "Last type"});
    newestFirst(t.sats, [&](const SbasSat& x) {
        s.row({std::to_string(x.prn), gnssChStateName(x.state), fmt("%.1f", (double)x.cn0), fmt("%+.0f Hz", x.dopplerHz), std::to_string(x.messages), std::to_string(x.framesBad), x.lastType >= 0 ? std::to_string(x.lastType) : ""});
    });
    o.table(s);
    Table l("Messages", {"Signal time", "PRN", "Type", "What it says"});
    newestLast(t.log, [&](const sbas::LogEntry& x) { l.row({fmt("%.1f s", x.timeS), std::to_string(x.prn), std::to_string(x.type), clip(x.text)}); });
    o.table(l);
}

void inmsatAll(Out& o, const InmsatTelemetry& t) {
    static const char* const kState[] = {"searching", "carriers found", "decoding"};
    signal(o, kState[std::clamp(t.state, 0, 2)], t.snrDb, -200, t.cfoHz, "Eb/N0");
    if (t.sat.valid) o.card("Satellite", t.sat.name);
    o.card("Carriers", std::to_string(t.carriers.size()));
    o.card("Messages", num(t.messagesTotal));
    o.card("Positions", num(t.positionsTotal));
    o.card("SUs ok / bad", okBad(t.susOk, t.susBad));
    if (t.activeCalls > 0) o.card("Calls now", std::to_string(t.activeCalls));
    Table a("Aircraft", {"ICAO", "Registration", "Flight", "Msgs", "Last label", "Position", "Alt ft"});
    newestFirst(t.aircraft, [&](const AeroAircraft& x) {
        a.row({fmt("%06X", x.aesId), x.registration, x.flight, std::to_string(x.messages), x.lastLabel, x.hasPos ? fmt("%.3f, %.3f", x.lat, x.lon) : "", x.hasAlt ? std::to_string(x.altFt) : ""});
    });
    o.table(a);
    Table m("Messages", {"Time UTC", "From", "To", "Registration", "Flight", "Label", "Text"});
    newestLast(t.messages, [&](const AeroMessage& x) {
        const std::string plane = fmt("%06X", x.aesId);
        m.row({hhmmss(x.wallTime), x.uplink ? "Ground" : plane, x.uplink ? plane : "Ground", x.registration, x.flight, x.label, clip(x.decoded.empty() ? x.text : x.decoded)});
    });
    o.table(m);
    Table e("Inmarsat-C", {"Time", "Service", "Area", "Station", "Complete", "Text"});
    newestFirst(t.egc, [&](const InmcMessage& x) { e.row({x.rxTime, x.serviceText, x.area, x.lesName, yesNo(x.complete), clip(x.text)}); });
    o.table(e);
    Table c("Carriers", {"Frequency", "Satellite", "Type", "Rate", "Level", "Eb/N0", "State", "Frames"});
    static const char* const kCarrier[] = {"seen", "locked", "frames", "data"};
    newestFirst(t.carriers, [&](const inmsat::CarrierRow& x) {
        c.row({x.freqHz > 0 ? fmt("%.4f MHz", x.freqHz / 1e6) : fmt("%+.1f kHz", x.offsetHz / 1e3), x.satellite, inmsat::carrierTypeName(x.type), x.bitRate ? std::to_string(x.bitRate) : "",
               fmt("%.0f dB", (double)x.snrDb), fmt("%.1f dB", (double)x.ebn0Db), kCarrier[std::clamp(x.state, 0, 3)], num(x.frames)});
    });
    o.table(c);
}

void pskDemod(Out& o, const PskdTelemetry& t) {
    static const char* const kState[] = {"searching", "signal, no lock", "locked"};
    signal(o, kState[std::clamp(t.state, 0, 2)], t.snrDb, t.levelDb, t.cfoHz);
    o.card("Status", t.status);
    if (t.signal) {
        o.card("Order", pskdOrderName(t.order));
        if (t.rateFound) o.card("Symbol rate", fmt("%.1f Bd%s", t.baud, t.baudSnapped ? " (standard rate)" : ""));
        if (!t.shape.empty()) o.card("Pulse shape", t.shape);
        o.card("Bandwidth", fmt("%.0f Hz", t.bw3Hz));
        o.card("Doppler rate", fmt("%+.1f Hz/s", t.dopplerHzPerSec));
        o.card("Eb/N0", fmt("%.1f dB", t.ebn0Db));
        o.card("MER", fmt("%.1f dB", t.merDb));
    }
    o.card("Symbols", num(t.symbols));
    o.card("Sync words", num(t.syncs));
    Table r("Rates", {"Rate", "Strength", "From"});
    newestFirst(t.rates, [&](const PskdRate& x) { r.row({fmt("%.1f Bd", x.baud), fmt("%.2f", x.conf), x.how}); });
    o.table(r);
    eventsTable(o, t.log);
}

// ---- time

void timeSignal(Out& o, const TimeTelemetry& t) {
    static const char* const kState[] = {"searching", "seconds found", "time decoded"};
    o.card("Station", timesig::stationName(t.station));
    signal(o, kState[std::clamp(t.state, 0, 2)], t.snrDb, t.levelDb, t.cfoHz);
    if (t.timeValid) {
        o.card("Received time", dateTime(t.utcNow));
        o.card("Confirmed", yesNo(t.confirmed));
    }
    o.card("Minutes ok / rejected", okBad(t.blocksOk, t.blocksBad));
    if (t.secondOfMinute >= 0) o.card("Second", std::to_string(t.secondOfMinute));
    if (t.state >= 1) o.card("Tick jitter", fmt("%.2f ms", t.tickJitterMs));
    if (t.clockValid) {
        o.card("Computer clock", fmt("%+.1f ms", t.clockOffsetMs));
        o.card("Computer clock, averaged", fmt("%+.1f ms", t.clockOffsetAvgMs));
    }
    if (t.locationSet) o.card("Distance, path delay", fmt("%.0f km, %.2f ms", t.distanceKm, t.propDelayMs));
    if (t.fields.dst >= 0) o.card("Summer time", yesNo(t.fields.dst > 0));
    if (t.fields.leapAnnounce) o.card("Leap second", "announced");
    if (t.fields.dut1 != 99) o.card("DUT1", fmt("%+.1f s", t.fields.dut1 / 10.0));
    Table l("Minutes", {"Computer UTC", "Minute", "Symbols"});
    newestFirst(t.log, [&](const TimeFrameLog& x) { l.row({hhmmss(x.wallTime), x.text, x.bits}); });
    o.table(l);
}

void eczas(Out& o, const EczasTelemetry& t) {
    static const char* const kState[] = {"no carrier", "carrier found", "time decoded"};
    signal(o, kState[std::clamp(t.state, 0, 2)], t.snrDb, t.levelDb, t.cfoHz);
    if (t.timeValid) {
        o.card("Received time", dateTime(t.utcNow));
        o.card("Local offset", fmt("+%d h", t.pkt.tzHours));
        o.card("Confirmed", yesNo(t.confirmed));
        o.card("Last packet", ago(t.ageSec));
        o.card("Transmitter", eczas::txStateText(t.pkt.txState));
        if (t.pkt.leapAnnounce) o.card("Leap second", t.pkt.leapSubtract ? "announced, subtract" : "announced, add");
        if (t.pkt.dstChangeSoon) o.card("Summer time", "change soon");
    }
    o.card("Time packets ok / bad CRC", okBad(t.blocksOk, t.blocksBad));
    if (t.clockValid) {
        o.card("Computer clock", fmt("%+.1f ms", t.clockOffsetMs));
        o.card("Computer clock, averaged", fmt("%+.1f ms", t.clockOffsetAvgMs));
    }
    if (t.locationSet) o.card("Distance, path delay", fmt("%.0f km, %.2f ms", t.distanceKm, t.propDelayMs));
    Table l("Frames", {"Time UTC", "Frame", "Result"});
    newestFirst(t.log, [&](const EczasFrameLog& x) { l.row({hhmmss(x.wallTime), x.hex, x.text}); });
    o.table(l);
}

// ---- science

void meteorScatter(Out& o, const MsTelemetry& t) {
    static const char* const kState[] = {"no beacon", "beacon found", "pings counted"};
    signal(o, kState[std::clamp(t.state, 0, 2)], t.snrDb, t.levelDb, t.cfoHz);
    o.card("Pings", num(t.blocksOk));
    o.card("Pings per hour", fmt("%.0f", (double)t.ratePerHour));
    int day = 0;
    for (int n : t.hourly) day += n;
    o.card("Last 24 hours", std::to_string(day));
    o.card("Rejected", num(t.rejected));
    if (t.active) o.card("Ping now", fmt("%.1f dB", (double)t.activeSnrDb));
    Table p("Pings", {"Time UTC", "Duration", "Peak", "Doppler", "Drift", "Type"});
    newestFirst(t.pings, [&](const MsPing& x) {
        p.row({hhmmss(x.wallTime), fmt("%.2f s", (double)x.durationSec), fmt("%.1f dB", (double)x.peakSnrDb), fmt("%+.0f Hz", (double)x.dopplerHz), fmt("%+.1f Hz/s", (double)x.driftHzPerSec), x.kind ? "overdense" : "underdense"});
    });
    o.table(p);
    Table s("Showers", {"Shower", "Peak", "Rate", "Now"});
    newestFirst(t.showers, [&](const MsShower& x) {
        s.row({x.name, x.peakDayDelta == 0 ? "today" : x.peakDayDelta > 0 ? fmt("in %d days", x.peakDayDelta) : fmt("%d days ago", -x.peakDayDelta), std::to_string(x.zhr),
               std::string(x.active ? "active" : "") + (x.daytime ? " daytime" : "")});
    });
    o.table(s);
}

void iono(Out& o, const IonoTelemetry& t) {
    o.card("State", t.state ? "searching" : "waiting for samples");
    o.card("Input power", fmt("%.1f dBFS", t.powerDb));
    o.card("Span", fmt("%.2f to %.2f MHz", t.spanLoHz / 1e6, t.spanHiHz / 1e6));
    o.card("Sounders", std::to_string(t.sounders.size()));
    o.card("Sweeps in the span", std::to_string(t.activeSweeps));
    Table s("Sounders", {"Name", "Rate kHz/s", "Period s", "Offset s", "Sweeps", "Missed", "SNR dB", "Band MHz", "Next s", "foF2", "foE", "h'F", "MUF(3000)", "Path MUF", "Distance km"});
    const auto& known = iono::knownSounders();
    newestFirst(t.sounders, [&](const IonoSounder& x) {
        const IonoScaling& c = x.scale;
        const bool named = c.known >= 0 && c.known < (int)known.size() && c.knownMatch > 0;
        s.row({named ? known[(size_t)c.known].name : fmt("Sounder %d", x.id), fmt("%.0f", x.rateHz / 1e3), x.periodSec > 0 ? fmt("%.0f", x.periodSec) : "", x.periodSec > 0 ? fmt("%.1f", x.offsetSec) : "",
               std::to_string(x.sweeps), std::to_string(x.missed), fmt("%.0f", x.snrDb), fmt("%.1f to %.1f", x.fLoHz / 1e6, x.fHiHz / 1e6), x.nextT0 > 0 ? fmt("%.0f", x.nextT0 - t.nowSec) : "",
               orBlank(c.foF2, "%.2f") + (c.foF2Above ? "+" : ""), orBlank(c.foE, "%.2f") + (c.foEAbove ? "+" : ""), orBlank(c.hF, "%.0f"), orBlank(c.muf3000, "%.2f"),
               orBlank(c.pathMuf, "%.2f") + (c.pathMufAbove ? "+" : ""), orBlank(c.distKm, "%.0f")});
    });
    o.table(s);
    Table w("Sweeps", {"Time", "Sounder", "Rate kHz/s", "Band MHz", "SNR dB", "Predicted"});
    newestLast(t.timeline, [&](const IonoEvent& x) {
        // with a radio the stream time is UTC seconds; a file or the test signal runs from 0
        w.row({x.t0 > 1e9 ? hhmmss((int64_t)x.t0) : fmt("%.0f s", x.t0), std::to_string(x.sounder), fmt("%.0f", x.rateHz / 1e3), fmt("%.1f to %.1f", x.fLoHz / 1e6, x.fHiHz / 1e6), fmt("%.0f", x.snrDb), yesNo(x.predicted)});
    });
    o.table(w);
}

void astro(Out& o, const AstroTelemetry& t) {
    o.card("State", t.state ? "integrating" : "waiting for samples");
    o.card("Input power", fmt("%.1f dBFS", t.powerDb));
    o.card("Span", fmt("%.3f MHz", t.rate / 1e6));
    o.card("FFT size", std::to_string(t.fftSize));
    o.card("Integration", fmt("%.0f of %.0f s (%.0f %%)", t.doneSec, t.integrationSec, t.progress * 100.0));
    o.card("Integrations finished", num(t.completed));
    if (t.switching) o.card("Frequency switching", fmt("%.0f kHz", t.switchHz / 1e3));
    const std::vector<double>& v = t.last.empty() ? t.avg : t.last;
    const size_t n = v.size();
    if (n < 16 || t.rate <= 0) return;
    std::vector<double> sorted(v);
    std::nth_element(sorted.begin(), sorted.begin() + (long)(n / 2), sorted.end());
    const double median = sorted[n / 2];
    if (median <= 0) return;
    // the middle of the band has the radio's DC spike: it is left out of the strongest bin
    size_t peak = 0;
    for (size_t i = 0; i < n; i++) if ((i + 2 < n / 2 || i > n / 2 + 2) && v[i] > v[peak]) peak = i;
    const auto kHzOf = [&](double bin) { return (bin - n / 2.0) * t.rate / (double)n / 1e3; };
    o.card("Strongest bin", fmt("%+.1f kHz, %.2f dB over the median", kHzOf((double)peak), 10 * std::log10(v[peak] / median)));
    // the spectrum in 128 steps, in dB over its median
    constexpr size_t kSteps = 128;
    Table s(t.last.empty() ? "Running average" : "Last integration", {"Offset kHz", "dB"});
    for (size_t k = 0; k < kSteps; k++) {
        const size_t a = k * n / kSteps, b = std::max(a + 1, (k + 1) * n / kSteps);
        double sum = 0;
        for (size_t i = a; i < b; i++) sum += v[i];
        s.row({fmt("%+.1f", kHzOf((a + b) / 2.0)), fmt("%.3f", 10 * std::log10(std::max(sum / (double)(b - a), 1e-30) / median))});
    }
    o.table(s);
}

// ---- pictures

// RGBA at black, opaque, of a picture W x H, thinned by a whole factor when it is too big for the phone
struct Canvas {
    int step = 1, w = 0, h = 0;
    std::vector<uint8_t> px;
    Canvas(int W, int H) {
        while ((int64_t)(W / step) * (H / step) > kMaxPicturePixels) step++;
        w = W / step; h = H / step;
        px.assign((size_t)w * h * 4, 0);
        for (size_t i = 3; i < px.size(); i += 4) px[i] = 255;
    }
    uint8_t* row(int y) { return px.data() + (size_t)y * w * 4; }
    bool give(std::vector<uint8_t>& out, int& outW, int& outH) { out.swap(px); outW = w; outH = h; return true; }
};

// what the caller keeps in seq: the mode with a counter of its picture, so that a change of mode is a change of seq
uint64_t pictureKey(int standard, uint64_t a, uint64_t b = 0) { return ((uint64_t)standard << 52) ^ (a << 32) ^ b; }

void paintRgb(Canvas& c, const uint8_t* rgb, int W) {
    for (int y = 0; y < c.h; y++) {
        const uint8_t* s = rgb + (size_t)y * c.step * W * 3;
        uint8_t* p = c.row(y);
        for (int x = 0; x < c.w; x++, p += 4, s += 3 * c.step) { p[0] = s[0]; p[1] = s[1]; p[2] = s[2]; }
    }
}
void paintGrey(Canvas& c, const uint8_t* grey, int W) {
    for (int y = 0; y < c.h; y++) {
        const uint8_t* s = grey + (size_t)y * c.step * W;
        uint8_t* p = c.row(y);
        for (int x = 0; x < c.w; x++, p += 4, s += c.step) p[0] = p[1] = p[2] = *s;
    }
}

bool sstvPicture(const HfdigSstvImage* im, uint64_t key, std::vector<uint8_t>& rgba, int& w, int& h, uint64_t& seq) {
    if (!im || im->width <= 0 || im->height <= 0 || im->rgb.size() < (size_t)im->width * im->height * 3 || key == seq) return false;
    Canvas c(im->width, im->height);
    paintRgb(c, im->rgb.data(), im->width);
    seq = key;
    return c.give(rgba, w, h);
}

bool kaitPicture(const KaitTelemetry& t, int standard, std::vector<uint8_t>& rgba, int& w, int& h, uint64_t& seq) {
    const uint64_t key = pictureKey(standard, 0, t.imageSeq);
    if (!t.image || t.image->w <= 0 || t.image->h <= 0 || t.image->rgb.size() < (size_t)t.image->w * t.image->h * 3 || key == seq) return false;
    Canvas c(t.image->w, t.image->h);
    paintRgb(c, t.image->rgb.data(), t.image->w);
    seq = key;
    return c.give(rgba, w, h);
}

// the decoder with the newest picture
bool shortwavePicture(const ShortwaveTelemetry& t, int standard, std::vector<uint8_t>& rgba, int& w, int& h, uint64_t& seq) {
    const SwDecoderStatus* best = nullptr;
    for (const SwDecoderStatus& d : t.decoders) if (d.image && d.image->w > 0 && d.image->h > 0 && (!best || d.imageSeq > best->imageSeq)) best = &d;
    if (!best) return false;
    const SwImage& im = *best->image;
    const uint64_t key = pictureKey(standard, (uint64_t)best->id + 1, best->imageSeq);
    if (key == seq || im.px.size() < (size_t)im.w * im.h * (im.gray ? 1 : 3)) return false;
    Canvas c(im.w, im.h);
    if (im.gray) paintGrey(c, im.px.data(), im.w); else paintRgb(c, im.px.data(), im.w);
    seq = key;
    return c.give(rgba, w, h);
}

// The desktop's automatic view with its default enhancement (as received): colour 123 by day, 125 at night, else the one channel there is
bool meteorPicture(const MeteorTelemetry& t, int standard, std::vector<uint8_t>& rgba, int& w, int& h, uint64_t& seq) {
    const uint64_t key = pictureKey(standard, 0, t.imageSeq);
    if (!t.image || t.image->rows <= 0 || key == seq) return false;
    const MeteorImage& im = *t.image;
    const auto has = [&](int k) { return im.packets[(size_t)k] > 0; };
    int ch[3] = {0, 1, 2};
    if (!(has(0) && has(1) && has(2))) {
        if (has(0) && has(1) && has(4)) ch[2] = 4;
        else for (int k = 5; k >= 0; k--) if (has(k)) ch[0] = ch[1] = ch[2] = k;
    }
    const auto stripOf = [&](int k, int row) -> const MeteorStrip* {
        const auto& v = im.ch[(size_t)k];
        const MeteorStrip* s = (size_t)row < v.size() ? v[(size_t)row].get() : nullptr;
        return s && s->px.size() >= (size_t)8 * kMeteorWidth ? s : nullptr;
    };
    Canvas c(kMeteorWidth, im.rows * 8);
    for (int y = 0; y < c.h; y++) {
        const int line = y * c.step, row = line / 8;
        const size_t at = (size_t)(line % 8) * kMeteorWidth;
        const MeteorStrip* s[3] = {stripOf(ch[0], row), stripOf(ch[1], row), stripOf(ch[2], row)};
        uint8_t* p = c.row(y);
        for (int x = 0; x < c.w; x++, p += 4) {
            const size_t i = at + (size_t)x * c.step;
            for (int k = 0; k < 3; k++) if (s[k]) p[k] = s[k]->px[i];
        }
    }
    seq = key;
    return c.give(rgba, w, h);
}

// The desktop's first view: red channel 2, green channel 1, blue channel 4 inverted
bool hrptPicture(const HrptTelemetry& t, int standard, std::vector<uint8_t>& rgba, int& w, int& h, uint64_t& seq) {
    const uint64_t key = pictureKey(standard, 0, t.imageSeq);
    if (!t.image || t.image->lines <= 0 || key == seq) return false;
    const HrptImage& im = *t.image;
    Canvas c(kHrptWidth, im.lines);
    for (int y = 0; y < c.h; y++) {
        const size_t line = (size_t)y * c.step;
        const HrptLine* l = line < im.line.size() ? im.line[line].get() : nullptr;
        if (!l || l->px.size() < (size_t)4 * kHrptWidth) continue;
        const uint8_t* s = l->px.data();
        uint8_t* p = c.row(y);
        for (int x = 0; x < c.w; x++, p += 4) {
            const size_t i = (size_t)x * c.step;
            p[0] = s[kHrptWidth + i]; p[1] = s[i]; p[2] = (uint8_t)(255 - s[3 * kHrptWidth + i]);
        }
    }
    seq = key;
    return c.give(rgba, w, h);
}

// One picture per instrument: the one with colour and the most rows, else the one with the most rows. Its first desktop view: true colour, VIRR's false
// colour (red 2, green 1, blue 4 inverted), or channel 1 in grey, stretched for the microwave instruments whose values sit in a narrow band.
bool fy3Picture(const Fy3Telemetry& t, int standard, std::vector<uint8_t>& rgba, int& w, int& h, uint64_t& seq) {
    const auto colour = [](const Fy3Image& im, int ch[3]) {
        if (im.inst == fy3::Virr && im.channels >= 10) { ch[0] = 0; ch[1] = 8; ch[2] = 6; return true; }
        if ((im.inst == fy3::Mersi1 || im.inst == fy3::Mersi2 || im.inst == fy3::Mersi3) && im.channels >= 4) { ch[0] = 2; ch[1] = 1; ch[2] = 0; return true; }
        return false;
    };
    const Fy3Image* best = nullptr;
    int ch[3] = {0, 0, 0};
    for (const auto& p : t.images) {
        if (!p || p->rows <= 0 || p->width <= 0 || p->channels <= 0) continue;
        int tmp[3];
        const bool c = colour(*p, tmp), bestColour = best && colour(*best, ch);
        if (!best || (c && !bestColour) || (c == bestColour && p->rows > best->rows)) best = p.get();
    }
    const uint64_t key = pictureKey(standard, 0, t.imageSeq);
    if (!best || key == seq) return false;
    const Fy3Image& im = *best;
    const int W = im.width;
    const bool isColour = colour(im, ch), falseColour = !isColour && im.inst == fy3::Virr && im.channels >= 5;
    int lo = 0, hi = 255;
    if (!isColour && !falseColour && (im.inst == fy3::Mwri || im.inst == fy3::Mwri2)) {   // 2 % .. 98 % of the channel, as the desktop does
        uint32_t hist[256] = {}, n = 0;
        for (int r = 0; r < im.rows; r += 3) {
            const Fy3Row* l = (size_t)r < im.row.size() ? im.row[(size_t)r].get() : nullptr;
            if (!l || l->px.size() < (size_t)W) continue;
            for (int x = 0; x < W; x += 2) { hist[l->px[(size_t)x]]++; n++; }
        }
        if (n >= 50) {
            uint32_t acc = 0;
            for (int v = 0; v < 256; v++) { acc += hist[v]; if (acc >= n * 2 / 100) { lo = v; break; } }
            acc = 0;
            for (int v = 255; v >= 0; v--) { acc += hist[v]; if (acc >= n * 2 / 100) { hi = v; break; } }
            hi = std::max(hi, lo + 4);
        }
    }
    const size_t need = (size_t)W * (isColour ? std::max({ch[0], ch[1], ch[2]}) + 1 : falseColour ? 4 : 1);
    Canvas c(W, im.rows);
    for (int y = 0; y < c.h; y++) {
        const size_t line = (size_t)y * c.step;
        const Fy3Row* l = line < im.row.size() ? im.row[line].get() : nullptr;
        if (!l || l->px.size() < need) continue;
        const uint8_t* s = l->px.data();
        uint8_t* p = c.row(y);
        for (int x = 0; x < c.w; x++, p += 4) {
            const size_t i = (size_t)x * c.step, Ws = (size_t)W;
            if (isColour) { p[0] = s[ch[0] * Ws + i]; p[1] = s[ch[1] * Ws + i]; p[2] = s[ch[2] * Ws + i]; }
            else if (falseColour) { p[0] = s[Ws + i]; p[1] = s[i]; p[2] = (uint8_t)(255 - s[3 * Ws + i]); }
            else p[0] = p[1] = p[2] = (uint8_t)std::clamp((s[i] - lo) * 255 / std::max(1, hi - lo), 0, 255);
        }
    }
    seq = key;
    return c.give(rgba, w, h);
}

// The newest product that is a picture in grey. JPEG and GIF products stay in Product::data, not decoded here; encrypted GK-2A pictures have no pixels.
bool hritPicture(const GoesTelemetry& t, int standard, std::vector<uint8_t>& rgba, int& w, int& h, uint64_t& seq) {
    for (const auto& x : t.products) {
        if (!x) continue;
        std::lock_guard<std::mutex> lk(x->mu);   // the decoder thread is still adding rows
        if (x->w <= 0 || x->h <= 0 || x->rowsDone <= 0 || x->pix.size() < (size_t)x->w * x->h) continue;
        const uint64_t key = pictureKey(standard, x->id, x->version);
        if (key == seq) return false;
        Canvas c(x->w, x->h);
        paintGrey(c, x->pix.data(), x->w);
        seq = key;
        return c.give(rgba, w, h);
    }
    return false;
}

} // namespace

// The numbers are RxTelemetry::standard (the engine's standard minus one): the same ones as modeSummary() in core/src/engine/modes.cpp
bool satelliteScience(const RxTelemetry& rx, Out& o) {
    switch (rx.standard) {
    case 13: gnss(o, rx.gnss); return true;
    case 14: sonde(o, rx.sonde); return true;
    case 45: orbcomm(o, rx.orbcomm); return true;
    case 49: astro(o, rx.astro); return true;
    case 53: iono(o, rx.iono); return true;
    case 54: qo100(o, rx.qo100); return true;
    case 59: timeSignal(o, rx.timesig); return true;
    case 60: meteor(o, rx.meteor); return true;
    case 61: hritLink(o, rx.goes); hritTables(o, rx.goes); return true;
    case 62: cubesat(o, rx.cube); return true;
    case 63: globalstar(o, rx.globalstar); return true;
    case 65: hrpt(o, rx.hrpt); return true;
    case 81: elektro(o, rx.elektro); return true;
    case 86: eczas(o, rx.eczas); return true;
    case 93: sarsat(o, rx.sarsat); return true;
    case 105: meteorScatter(o, rx.mscatter); return true;
    case 121: dgps(o, rx.dgps); return true;
    case 142: goesDcs(o, rx.goesdcs); return true;
    case 151: sbas(o, rx.sbas); return true;
    case 153: argos(o, rx.argos); return true;
    case 202: loraSat(o, rx.lorasat); return true;
    case 203: pskDemod(o, rx.pskd); return true;
    case 207: ssdv(o, rx.ssdv); return true;
    case 209: inmsatAll(o, rx.inmsat); return true;
    case 231: case 232: gk2a(o, rx.gk2a); return true;
    case 233: case 234: case 235: fygeo(o, rx.fygeo); return true;
    case 236: fy3(o, rx.fy3a); return true;
    case 237: fy3(o, rx.fy3m); return true;
    default: return false;
    }
}

bool latestImage(const RxTelemetry& rx, std::vector<uint8_t>& rgba, int& w, int& h, uint64_t& seq) {
    const int s = rx.standard;
    switch (s) {
    case 26: return sstvPicture(rx.hfdig.sstv.image.get(), pictureKey(s, 0, rx.hfdig.sstv.imageSeq), rgba, w, h, seq);
    case 54: return !rx.qo100.autoDec.images.empty() && sstvPicture(rx.qo100.autoDec.images.front().get(), pictureKey(s, 0, rx.qo100.autoDec.imageSeq), rgba, w, h, seq);
    case 60: return meteorPicture(rx.meteor, s, rgba, w, h, seq);
    case 61: return hritPicture(rx.goes, s, rgba, w, h, seq);
    case 65: return hrptPicture(rx.hrpt, s, rgba, w, h, seq);
    case 81: return !elektroIsGgak(rx.elektro.link) && hritPicture(rx.elektro.hrit, s, rgba, w, h, seq);
    case 132: return kaitPicture(rx.kait, s, rgba, w, h, seq);
    case 213: return shortwavePicture(rx.shortwave, s, rgba, w, h, seq);
    case 231: case 232: return hritPicture(rx.gk2a, s, rgba, w, h, seq);
    case 233: case 234: case 235: return hritPicture(rx.fygeo, s, rgba, w, h, seq);
    case 236: return fy3Picture(rx.fy3a, s, rgba, w, h, seq);
    case 237: return fy3Picture(rx.fy3m, s, rgba, w, h, seq);
    default: return false;
    }
}

} // namespace onair::results
