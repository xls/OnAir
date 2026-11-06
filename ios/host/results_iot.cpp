// Cards and tables for the cellular, railway, IoT and short-range modes (mode_table.cpp groups 6 and 8) that android/native/src/results_json.cpp leaves to a one-line summary.
// rx.standard is the family number + 1 for all of these. LoRaWAN, Meshtastic and MeshCore (21), ISM sensors (29) and Bluetooth LE (52) are exported by results_json.cpp.
#include "results_kit.h"
#include "dect2/esubghz/esubghz_proto.h"
#include "dect2/halow/halow_mac.h"
#include "dect2/lorawan/lorawan_plan.h"
#include "dect2/wifi/wifi_chan.h"
#include "dect2/wifi/wifi_proto.h"
#include "dect2/zwave/zwave_proto.h"
#include <algorithm>
#include <bit>
#include <cstdarg>
#include <ctime>
#include <ranges>
#include <vector>

namespace onair::results {
using namespace dect2;

namespace {
constexpr size_t kRows = 200;

__attribute__((format(printf, 1, 2))) std::string fmt(const char* format, ...) {
    char b[512];
    va_list ap; va_start(ap, format); vsnprintf(b, sizeof b, format, ap); va_end(ap);
    return b;
}
std::string num(uint64_t v) { return std::to_string(v); }
std::string orBlank(int v, int none = -1) { return v == none ? "" : std::to_string(v); }
std::string join(const std::string& a, const std::string& b, const char* sep = ", ") { return a.empty() ? b : b.empty() ? a : a + sep + b; }
std::string clockUtc(int64_t wall) {
    if (!wall) return "";
    const time_t t = (time_t)wall;
    struct tm tm;
    gmtime_r(&t, &tm);
    return fmt("%02d:%02d:%02d", tm.tm_hour, tm.tm_min, tm.tm_sec);
}
std::string secondsSince(double now, double then) { return fmt("%.0f", std::max(0.0, now - then)); }   // signal time, as the desktop's "ago"
std::string secondsSinceWall(int64_t wall) { return wall ? std::to_string(std::max<int64_t>(0, (int64_t)time(nullptr) - wall)) : ""; }
std::string panText(int pan) { return pan < 0 ? "" : fmt("0x%04X", (unsigned)pan); }

// The first rows of a list kept newest first, or the last rows, newest first, of one kept oldest first
template <class C> auto newest(const C& c, size_t n = kRows) { return c | std::views::take((std::ptrdiff_t)n); }
template <class C> auto newestOfOldestFirst(const C& c, size_t n = kRows) { return c | std::views::reverse | std::views::take((std::ptrdiff_t)n); }
// The same for a list in no useful order
template <class T, class Key> std::vector<const T*> newestBy(const std::vector<T>& c, Key key) {
    std::vector<const T*> out;
    for (const T& x : c) out.push_back(&x);
    std::sort(out.begin(), out.end(), [&](const T* a, const T* b) { return key(*a) > key(*b); });
    if (out.size() > kRows) out.resize(kRows);
    return out;
}
// DevicesPage shows only the table with the most rows (the first of equals), so a log must not outgrow the devices it sits under
size_t besideDevices(const Table& devices) { return devices.count() ? (size_t)devices.count() : kRows; }

void common(Out& o, const char* state, float snr, float level, double cfo, uint64_t ok, uint64_t bad, const char* blocks = "Blocks ok / bad") {
    o.card("State", state);
    if (snr != 0) o.card("SNR", fmt("%.1f dB", snr));
    if (level > -199) o.card("Level", fmt("%.1f dBFS", level));
    if (cfo != 0) o.card("CFO", fmt("%+.0f Hz", cfo));
    o.card(blocks, num(ok) + " / " + num(bad));
}
const char* heard(int state) { return state >= 1 ? "receiving" : "listening"; }
const char* cellState(int state) { return state >= 2 ? "cell found" : state == 1 ? "searching" : "no input"; }

template <class C> void events(Out& o, const C& list, size_t limit, const char* from) {
    Table t("Events", {"Time UTC", "From", "To", "Text"});
    for (const auto& e : newest(list, limit)) t.row({clockUtc(e.wallTime), from, "", e.text});
    o.table(t);
}
std::string operatorOf(const std::string& op, const std::vector<std::string>& plmns) { return !op.empty() ? op : plmns.empty() ? "" : plmns[0]; }

void cellTowers(Out& o, const CellTelemetry& a) {
    common(o, cellState(a.state), a.snrDb, a.levelDb, a.cfoHz, a.blocksOk, a.blocksBad, "SI messages ok / bad");
    size_t named = 0;
    for (const CellTower& c : a.cells) if (c.hasSib1) named++;
    o.card("Cells", num(a.cells.size()));
    o.card("Identified", num(named));
    if (!a.carriers.empty()) o.card("LTE carriers in view", num(a.carriers.size()));
    Table t("Cells", {"Id", "Name", "Band", "EARFCN", "MHz", "PCI", "eNB / sector", "TAC", "Width", "RSRP", "RSRQ", "SINR", "Level", "Barred", "Last s"});
    for (const CellTower& c : newest(a.cells)) {
        const std::string rsrp = fmt("%.1f", c.rsrpDb);
        t.row({c.hasSib1 ? num(c.cellId) : fmt("PCI %d", c.pci), operatorOf(c.op, c.plmns), c.band ? std::to_string(c.band) : "", orBlank(c.earfcn), fmt("%.1f", c.freqHz / 1e6),
               std::to_string(c.pci), c.hasSib1 ? fmt("%u / %d", c.enb, c.sector) : "", c.hasSib1 ? num(c.tac) : "", c.hasMib ? fmt("%.1f MHz", c.nRb * 0.2) : "", rsrp,
               c.rsrqDb > -99 ? fmt("%.1f", c.rsrqDb) : "", c.sinrDb > -99 ? fmt("%.1f", c.sinrDb) : "", rsrp, c.hasSib1 ? (c.barred ? "yes" : "no") : "", secondsSinceWall(c.lastWall)});
    }
    o.table(t);
    events(o, a.events, besideDevices(t), "LTE");
}

void nrCells(Out& o, const NrTelemetry& a) {
    common(o, cellState(a.state), a.snrDb, a.levelDb, a.cfoHz, a.blocksOk, a.blocksBad, "PBCH ok / bad");
    size_t mib = 0;
    for (const NrCell& c : a.cells) if (c.hasMib) mib++;
    o.card("Cells", num(a.cells.size()));
    o.card("With MIB", num(mib));
    Table t("Cells", {"Id", "Name", "Band", "GSCN", "MHz", "PCI", "SSB", "Beams", "SFN", "SIB1", "RSRP", "RSRQ", "SINR", "Level", "Last s"});
    for (const NrCell& c : newest(a.cells)) {
        const std::string rsrp = fmt("%.1f", c.rsrpDb);
        t.row({fmt("PCI %d", c.pci), c.band ? fmt("n%d", c.band) : "", c.band ? std::to_string(c.band) : "", orBlank(c.gscn), fmt("%.2f", c.freqHz / 1e6), std::to_string(c.pci),
               fmt("%d kHz", c.scsKhz), num(c.beams.size()), c.hasMib ? std::to_string(c.sfn) : "", c.hasMib ? (c.sib1Scheduled ? "yes" : "no") : "", rsrp,
               c.rsrqDb > -99 ? fmt("%.1f", c.rsrqDb) : "", c.sinrDb > -99 ? fmt("%.1f", c.sinrDb) : "", rsrp, secondsSinceWall(c.lastWall)});
    }
    o.table(t);
    events(o, a.events, besideDevices(t), "5G NR");
}

void nbiotCells(Out& o, const NbiotTelemetry& a) {
    common(o, cellState(a.state), a.snrDb, a.levelDb, a.cfoHz, a.blocksOk, a.blocksBad, "SIB1-NB ok / bad");
    size_t named = 0;
    for (const NbCell& c : a.cells) if (c.hasSib1) named++;
    o.card("Cells", num(a.cells.size()));
    o.card("Identified", num(named));
    Table t("Cells", {"Id", "Name", "Band", "EARFCN", "MHz", "PCI", "Mode", "eNB / sector", "TAC", "Level", "SNR", "Last s"});
    for (const NbCell& c : newest(a.cells)) {
        t.row({c.hasSib1 ? num(c.cellId) : fmt("PCI %d", c.pci), operatorOf(c.op, c.plmns), c.band ? std::to_string(c.band) : "", orBlank(c.earfcn), fmt("%.1f", c.freqHz / 1e6), std::to_string(c.pci),
               c.mode >= 0 ? nbiotModeName(c.mode) : "", c.hasSib1 ? fmt("%u / %d", c.enb, c.sector) : "", c.hasSib1 ? num(c.tac) : "", fmt("%.1f", c.levelDb),
               c.snrDb > -99 ? fmt("%.1f", c.snrDb) : "", secondsSinceWall(c.lastWall)});
    }
    o.table(t);
    events(o, a.events, besideDevices(t), "NB-IoT");
}

void gsmr(Out& o, const GsmrTelemetry& a) {
    common(o, cellState(a.state), a.snrDb, a.levelDb, a.cfoHz, a.blocksOk, a.blocksBad, "SI messages ok / bad");
    size_t named = 0, rail = 0;
    for (const GsmrCell& c : a.cells) { if (c.hasLai) named++; if (c.railway) rail++; }
    o.card("Cells", num(a.cells.size()));
    o.card("Identified", num(named));
    o.card("In the railway band", num(rail));
    Table t("Cells", {"Id", "Name", "ARFCN", "MHz", "BSIC", "LAC", "Cell", "Band", "Level", "SNR", "Last s"});
    for (const GsmrCell& c : newest(a.cells)) {
        const std::string plmn = c.hasLai ? (c.mncDigits == 3 ? fmt("%03d-%03d", c.mcc, c.mnc) : fmt("%03d-%02d", c.mcc, c.mnc)) : "";
        t.row({fmt("ARFCN %d / BSIC %d", c.arfcn, c.bsic), c.op.empty() ? plmn : c.op, orBlank(c.arfcn), fmt("%.1f", c.freqHz / 1e6), c.bsic >= 0 ? fmt("%d-%d", c.ncc, c.bcc) : "",
               c.hasLai ? num(c.lac) : "", c.hasSi3 ? num(c.cellId) : "", c.railway ? "GSM-R" : "GSM", fmt("%.1f", c.levelDb), c.snrDb > -99 ? fmt("%.1f", c.snrDb) : "", secondsSinceWall(c.lastWall)});
    }
    events(o, a.events, kRows, "GSM-R");   // first: TexterPage shows the first table with a Text column
    o.table(t);
}

void lbj(Out& o, const LbjTelemetry& a) {
    common(o, a.state >= 2 ? "receiving" : a.state == 1 ? "listening" : "no input", a.snrDb, a.levelDb, a.cfoHz, a.blocksOk, a.blocksBad, "Messages ok / bad");
    o.card("Bursts", num(a.bursts));
    Table t("Messages", {"Time UTC", "From", "To", "Text", "Speed km/h", "Km post", "Direction", "Locomotive", "Lat", "Lon", "Level"});
    for (const LbjMessage& m : newest(a.messages)) {
        std::string text = m.speedKmh.empty() ? "" : m.speedKmh + " km/h";
        if (!m.kmMarker.empty()) text = join(text, "km " + m.kmMarker);
        text = join(join(text, m.direction), m.loco);
        t.row({clockUtc(m.wallTime), m.train, m.route, text, m.speedKmh, m.kmMarker, m.direction, m.loco, m.positionValid ? fmt("%.5f", m.latitude) : "",
               m.positionValid ? fmt("%.5f", m.longitude) : "", fmt("%.0f", m.rssiDb)});
    }
    o.table(t);
}

void railwayLog(Out& o, const RailwayTelemetry& a) {
    common(o, a.state >= 2 ? "receiving" : a.state == 1 ? "listening" : "no input", a.snrDb, a.levelDb, a.cfoHz, a.blocksOk, a.blocksBad, "Messages ok / bad");
    Table t("Messages", {"Time UTC", "From", "To", "Text", "Train", "Speed km/h", "Km post", "Cars", "Pressure kPa"});
    for (const railway::Message& m : newest(a.messages)) {
        t.row({clockUtc(m.wallTime), m.locomotive, m.tailId, join(m.action, m.parameter), m.train, m.speedKmh ? num(m.speedKmh) : "", m.kilometerValid ? fmt("%.3f", m.kilometer) : "",
               m.carCount ? num(m.carCount) : "", m.pressureKpa >= 0 ? std::to_string(m.pressureKpa) : ""});
    }
    o.table(t);
}

void ebicab(Out& o, const EbicabTelemetry& a) {
    common(o, a.state >= 2 ? "telegrams" : a.state == 1 ? "bursts, no telegram" : "no signal", a.snrDb, a.levelDb, a.cfoHz, a.blocksOk, a.blocksBad, "Telegrams / other bursts");
    o.card("Long / short", num(a.longTelegrams) + " / " + num(a.shortTelegrams));
    o.card("Balises", num(a.balises.size()));
    if (a.bitRate > 0) o.card("Bit rate", fmt("%.0f bit/s", a.bitRate));
    Table t("Telegrams", {"Time UTC", "Length", "NID_C", "NID_BG", "N_PIG", "N_TOTAL", "M_VERSION", "Copies", "Detail"});
    for (const EbicabTelegram& x : newest(a.telegrams)) {
        const ebicab::Header& h = x.header;
        std::string detail = std::string(x.inverted ? "inverted  " : "") + (h.qUpdown ? "up-link  " : "down-link  ") + x.hex.substr(0, 40);
        t.row({clockUtc(x.utc), x.longFmt ? "1023" : "341", h.valid ? std::to_string(h.nidC) : "", h.valid ? std::to_string(h.nidBg) : "", h.valid ? std::to_string(h.nPig) : "",
               h.valid ? std::to_string(h.nTotal) : "", h.valid ? fmt("%d.%d", h.mVersion >> 4, h.mVersion & 15) : "", std::to_string(x.repeats), detail});
    }
    o.table(t);
    Table b("Balises", {"Id", "Name", "NID_C", "NID_BG", "Balise in group", "Group size", "Count", "Last s"});
    for (const EbicabBalise& x : newest(a.balises))
        b.row({fmt("%d/%d/%d", x.nidC, x.nidBg, x.nPig), "", std::to_string(x.nidC), std::to_string(x.nidBg), std::to_string(x.nPig), std::to_string(x.nTotal), num(x.count), secondsSinceWall(x.lastSeen)});
    o.table(b);
    Table u("Bursts", {"Time UTC", "Bits", "Duration us", "SNR dB", "First bits (hex)", "Hint"});
    for (const EbicabBurst& x : newest(a.burstLog)) u.row({clockUtc(x.utc), std::to_string(x.bits), fmt("%.0f", x.durationUs), fmt("%.1f", x.snrDb), x.head, x.hint});
    o.table(u);
}

void bleTrackers(Out& o, const BletrkTelemetry& a) {
    common(o, heard(a.state), a.snrDb, a.levelDb, a.cfoHz, a.blocksOk, a.blocksBad, "Packets ok / bad");
    o.card("Following you", std::to_string(a.followingNow));
    o.card("Trackers", num(a.trackers.size()));
    o.card("Alerts", num(a.alerts.size()));
    for (int k = 1; k < bletrk::kKinds; k++) if (a.nowByKind[k]) o.card(bletrk::kindName(k), std::to_string(a.nowByKind[k]));
    Table t("Trackers", {"Id", "Name", "State", "Stays min", "Near %", "RSSI", "Trend", "Addresses", "Packets", "Last s"});
    for (const BletrkTracker& d : newest(a.trackers)) {   // following first, then the longest staying; at most kBletrkMax
        t.row({num(d.id), d.label, d.ignored ? "your own" : d.following ? "following you" : d.separated ? "separated from its owner" : "nearby", fmt("%.0f", (d.lastSec - d.firstSec) / 60),
               fmt("%.0f", d.nearFrac * 100.0), fmt("%.0f", d.rssiAvg), d.trend > 0 ? "closer" : d.trend < 0 ? "farther" : "steady", std::to_string(d.addresses), num(d.packets),
               secondsSince(a.timeSec, d.lastSec)});
    }
    o.table(t);
    Table al("Alerts", {"Time UTC", "RSSI", "Text"});
    for (const BletrkAlert& x : newest(a.alerts, besideDevices(t))) al.row({clockUtc(x.wallTime), fmt("%.0f", x.rssiAvg), x.text});
    o.table(al);
}

void zigbee(Out& o, const ZigbeeTelemetry& a) {
    static const char* const phys[] = {"2.4 GHz O-QPSK", "868 MHz BPSK", "915 MHz BPSK"};
    common(o, heard(a.state), a.snrDb, a.levelDb, a.cfoHz, a.blocksOk, a.blocksBad, "Frames ok / bad");
    if (a.channel) o.card("Channel", std::to_string(a.channel));
    if (a.phy >= 0 && a.phy < 3) o.card("PHY", phys[a.phy]);
    o.card("Networks", num(a.pans.size()));
    o.card("Devices", num(a.devices.size()));
    o.card("Encrypted frames", num(a.encryptedFrames));
    Table t("Devices", {"Id", "Name", "Role", "Short", "PAN", "Ch", "RSSI", "Packets", "Last s", "Last frame"});
    for (const ZbDevice& d : newest(a.devices)) {
        t.row({d.extAddr.empty() ? d.shortAddr : d.extAddr, d.vendor, d.role, d.shortAddr, panText(d.pan), d.channel ? std::to_string(d.channel) : "", fmt("%.0f", d.rssi), num(d.packets),
               secondsSince(a.timeSec, d.lastSec), d.last});
    }
    o.table(t);
    const size_t limit = besideDevices(t);
    Table p("Networks", {"PAN ID", "Extended PAN ID", "Ch", "Coordinator", "Devices", "RSSI", "Packets", "Last s"});
    for (const ZbPan& x : newest(a.pans, limit)) {
        p.row({panText(x.pan), x.extPan, x.channel ? std::to_string(x.channel) : "", x.coordinator, std::to_string(x.devices), fmt("%.0f", x.rssi), num(x.packets), secondsSince(a.timeSec, x.lastSec)});
    }
    o.table(p);
    Table l("Frames", {"Time UTC", "From", "To", "Text", "Ch", "Type", "Len", "FCS", "RSSI"});
    for (const ZbFrame& f : newest(a.log, limit)) {
        l.row({clockUtc(f.wallTime), f.src, f.dst, f.info, f.channel ? std::to_string(f.channel) : "", f.encrypted ? f.type + " (encrypted)" : f.type, std::to_string(f.len), f.fcsOk ? "ok" : "bad", fmt("%.0f", f.rssi)});
    }
    o.table(l);
}

void halowNets(Out& o, const HalowTelemetry& a) {
    static const char* const preambles[] = {"S1G_SHORT", "S1G_LONG", "S1G_1M"};
    common(o, heard(a.state), a.snrDb, a.levelDb, a.cfoHz, a.blocksOk, a.blocksBad, "Frames ok / bad");
    if (a.centerMhz > 0) o.card("Tuned", fmt("%.1f MHz", a.centerMhz));
    o.card("Networks", num(a.nets.size()));
    o.card("SIG fields ok / bad", num(a.sigOk) + " / " + num(a.sigBad));
    o.card("Not decoded", num(a.undecoded));
    Table t("Networks", {"Id", "Name", "Vendor", "Ch", "MHz", "Width", "MCS", "NSS", "SNR", "Security", "Beacon", "RSSI", "Beacons", "Country", "Last s"});
    for (const HlNet& n : newest(a.nets)) {
        t.row({n.bssid, n.hasSsid ? n.ssid : n.hidden ? "(hidden)" : n.comp ? halow::compText(n.comp) : "", n.vendor, n.ccf ? std::to_string(n.ccf) : "", n.freqMhz > 0 ? fmt("%.1f", n.freqMhz) : "",
               n.seenWidthMhz ? fmt("%d MHz", n.seenWidthMhz) : "", std::to_string(n.mcs), std::to_string(n.nss), fmt("%.0f", n.snrDb), n.security, n.intervalTu ? fmt("%d TU", n.intervalTu) : "",
               fmt("%.0f", n.rssi), num(n.beacons), n.country, secondsSince(a.timeSec, n.lastSec)});
    }
    o.table(t);
    Table l("Frames", {"Time UTC", "BSSID", "Type", "Text", "Width", "MCS", "NSS", "Preamble", "SNR", "Len", "RSSI"});
    for (const HlFrame& f : newest(a.log, besideDevices(t))) {
        l.row({clockUtc(f.wallTime), f.bssid, f.type, f.info, fmt("%d MHz", f.widthMhz), std::to_string(f.mcs), std::to_string(f.nss), f.pre >= 0 && f.pre < 3 ? preambles[f.pre] : "",
               fmt("%.0f", f.snrDb), std::to_string(f.len), fmt("%.0f", f.rssi)});
    }
    o.table(l);
}

std::string antReadings(const AntDevice& d) {
    std::string r;
    if (d.heartRate > 0) r = join(r, fmt("%d bpm", d.heartRate), "  ");
    if (d.powerW >= 0) r = join(r, fmt("%d W", d.powerW), "  ");
    if (d.cadenceRpm >= 0) r = join(r, fmt("%d rpm", d.cadenceRpm), "  ");
    if (d.speedKmh >= 0) r = join(r, fmt("%.1f km/h", d.speedKmh), "  ");
    if (d.distanceM >= 0) r = join(r, fmt("%.0f m", d.distanceM), "  ");
    if (d.temperatureC > -999) r = join(r, fmt("%.1f C", d.temperatureC), "  ");
    return r;
}

void antSensors(Out& o, const AntTelemetry& a) {
    common(o, heard(a.state), a.snrDb, a.levelDb, a.cfoHz, a.blocksOk, a.blocksBad, "Frames ok / bad");
    if (a.channelMhz > 0) o.card("Channel", fmt("%.0f MHz", a.channelMhz));
    o.card("Sensors", num(a.devices.size()));
    Table t("Sensors", {"Id", "Name", "Readings", "Manufacturer", "Battery %", "RSSI", "Frames", "Last s"});
    for (const AntDevice& d : newest(a.devices)) {
        t.row({std::to_string(d.deviceNumber), d.typeName, antReadings(d), d.manufacturer, orBlank(d.batteryPct), fmt("%.0f", d.rssi), num(d.frames), secondsSince(a.timeSec, d.lastSec)});
    }
    o.table(t);
    Table l("Frames", {"Time UTC", "Sensor", "Type", "RSSI", "Decoded"});
    for (const AntFrameLog& f : newest(a.log, besideDevices(t))) {
        l.row({clockUtc(f.wall), std::to_string(f.deviceNumber), ant::deviceTypeName(f.type), fmt("%.0f", f.rssi), f.text});
    }
    o.table(l);
}

void dectBases(Out& o, const DectTelemetry& a) {
    common(o, heard(a.state), a.snrDb, a.levelDb, a.cfoHz, a.blocksOk, a.blocksBad, "A-fields ok / bad");
    if (a.carrier >= 0) o.card("Carrier", fmt("%d (%.3f MHz)", a.carrier, a.channelMhz));
    o.card("Base stations", num(a.bases.size()));
    o.card("Base bursts", num(a.baseBursts));
    o.card("Handset bursts", num(a.handsetBursts));
    Table t("Base stations", {"Id", "Name", "ARC", "EMC", "FPN", "Slots", "RSSI", "Frames", "Last s"});
    for (const DectBase& b : newest(a.bases)) {
        t.row({dect::hex40(b.rfpi), "", std::to_string(b.arc), orBlank(b.emc), orBlank(b.fpn), std::to_string(std::popcount(b.slotsMask)), fmt("%.0f", b.rssi), num(b.frames), secondsSince(a.timeSec, b.lastSec)});
    }
    o.table(t);
    Table l("Frames", {"Time UTC", "From", "RSSI", "Tail", "Content"});
    for (const DectLog& f : newest(a.log, besideDevices(t))) {
        l.row({clockUtc(f.wall), f.fromBase ? "base" : "handset", fmt("%.0f", f.rssi), dect::tailName(f.ta), dect::hex40(f.tail)});
    }
    o.table(l);
}

void wisun(Out& o, const WisunTelemetry& a) {
    common(o, heard(a.state), a.snrDb, a.levelDb, a.cfoHz, a.blocksOk, a.blocksBad, "Frames ok / bad");
    if (!a.bandName.empty()) o.card("Band plan", a.bandName);
    if (a.loMhz > 0) o.card("Covers", fmt("%.1f - %.1f MHz", a.loMhz, a.hiMhz));
    o.card("Networks", num(a.pans.size()));
    o.card("Nodes", num(a.nodes.size()));
    o.card("Links", num(a.links.size()));
    o.card("Encrypted frames", num(a.encryptedFrames));
    Table t("Nodes", {"Id", "Name", "Role", "PAN", "Cost", "RSSI", "Frames", "Last s", "Last frame"});
    for (const WsNode& d : newest(a.nodes)) {
        t.row({d.eui, d.vendor, d.role, panText(d.pan), orBlank(d.routingCost), fmt("%.0f", d.rssi), num(d.packets), secondsSince(a.timeSec, d.lastSec), d.last});
    }
    o.table(t);
    const size_t limit = besideDevices(t);
    Table p("Networks", {"PAN ID", "Network name", "Border router", "Size", "Heard", "RSSI", "Frames", "Last s", "Schedule"});
    for (const WsPan& x : newest(a.pans, limit)) {
        p.row({panText(x.pan), x.netName, x.borderRouter, orBlank(x.panSize), std::to_string(x.nodes), fmt("%.0f", x.rssi), num(x.packets), secondsSince(a.timeSec, x.lastSec), x.unicast});
    }
    o.table(p);
    Table k("Links", {"From", "To", "Frames", "Acks", "RSL", "RSSI", "Last s"});
    for (const WsLink& x : newest(a.links, limit)) {
        k.row({x.src, x.dst, num(x.frames), num(x.acks), x.rslDbm > -999 ? fmt("%d dBm", x.rslDbm) : "", fmt("%.0f", x.rssi), secondsSince(a.timeSec, x.lastSec)});
    }
    o.table(k);
    Table l("Frames", {"Time UTC", "From", "To", "Text", "MHz", "Ch", "kbit/s", "Type", "RSSI"});
    for (const WsFrame& f : newest(a.log, limit)) {
        l.row({clockUtc(f.wallTime), f.src, f.dst, f.info, fmt("%.3f", f.mhz), orBlank(f.channel), fmt("%g", f.bitRate / 1000.0), f.encrypted ? f.type + " (encrypted)" : f.type, fmt("%.0f", f.rssi)});
    }
    o.table(l);
}

void wmbusMeters(Out& o, const WmbusTelemetry& a) {
    common(o, a.state >= 2 ? "frames" : a.state == 1 ? "signal on a channel" : "no signal", a.snrDb, a.levelDb, a.cfoHz, a.blocksOk, a.blocksBad, "Frames ok / bad");
    o.card("Meters", num(a.devices.size()));
    o.card("Encrypted frames", num(a.encryptedFrames));
    o.card("Sync words", num(a.syncs));
    Table t("Meters", {"Id", "Name", "Readings", "Maker", "Mode", "Count", "Encrypted", "RSSI", "Last s"});
    for (const WmbusDevice& d : newest(a.devices)) {
        t.row({d.id, d.type, d.last, d.mfr, wmbus::phyName((wmbus::Phy)d.phy), num(d.count), d.encrypted ? "yes" : "no", fmt("%.0f", d.rssiDb), secondsSinceWall(d.lastSeen)});
    }
    o.table(t);
    const size_t limit = besideDevices(t);
    Table l("Frames", {"Time UTC", "Mode", "Meter", "Result", "RSSI", "Frame"});
    for (const WmbusFrameLog& f : newest(a.log, limit)) {
        l.row({clockUtc(f.wallTime), wmbus::phyName((wmbus::Phy)f.phy), join(f.mfr, f.id, " "), f.crcOk ? f.summary : join("CRC failed", f.summary), fmt("%.0f", f.rssiDb), f.hex});
    }
    o.table(l);
    Table c("Channels", {"Channel", "Mode", "Level", "Frames", "CRC failures"});
    for (const WmbusChannelInfo& x : newest(a.channels, limit)) c.row({x.name, x.modes, fmt("%.1f", x.levelDb), num(x.frames), num(x.bad)});
    o.table(c);
}

void nfcTags(Out& o, const NfcTelemetry& a) {
    static const char* const states[] = {"no input", "field present", "frames", "tag identified"};
    static const char* const protos[] = {"Type A", "Type B", "ISO 15693"};
    common(o, states[std::clamp(a.state, 0, 3)], a.snrDb, a.levelDb, 0, a.blocksOk, a.blocksBad, "Frames ok / bad");
    if (a.subcarrierDb > -199) o.card("Subcarrier", fmt("%.1f dBFS", a.subcarrierDb));
    o.card("Tags", num(a.tags.size()));
    o.card("NDEF records", num(a.ndef.size()));
    Table t("Tags", {"Id", "Name", "ATQA", "SAK", "ATS", "Seen"});
    for (const NfcTag* x : newestBy(a.tags, [](const NfcTag& g) { return g.lastSeen; })) {
        t.row({x->uid, x->type, x->haveAtqa ? fmt("%04X", x->atqa) : "", x->haveSak ? fmt("%02X", x->sak) : "", x->ats, std::to_string(x->seenCount)});
    }
    o.table(t);
    const size_t limit = besideDevices(t);
    Table d("NDEF", {"Tag", "Type", "Language", "Text"});
    for (const NfcNdef& x : newest(a.ndef, limit)) d.row({x.uid, x.type, x.lang, x.text.empty() ? x.uri : x.text});
    o.table(d);
    Table l("Frames", {"Time (ms)", "From", "Proto", "Bytes", "CRC", "Decoded"});   // the receiver keeps signal time only, no clock time
    for (const NfcLogEntry& f : newestOfOldestFirst(a.log, limit)) {
        l.row({fmt("%.2f", f.timeSec * 1e3), f.fromReader ? "reader" : "tag", f.proto >= 0 && f.proto < 3 ? protos[f.proto] : "", f.hex, f.crcChecked ? (f.crcOk ? "ok" : "bad") : "", f.note});
    }
    o.table(l);
}

void zwave(Out& o, const ZwaveTelemetry& a) {
    common(o, a.state >= 2 ? "frames" : a.state == 1 ? "bursts" : "listening", a.snrDb, a.levelDb, a.cfoHz, a.blocksOk, a.blocksBad, "Frames ok / bad");
    if (!a.regionName.empty()) o.card("Region", a.regionName);
    o.card("Channels covered", std::to_string(a.channelsCovered));
    o.card("Networks", num(a.networks.size()));
    o.card("Nodes", num(a.nodes.size()));
    o.card("S0 / S2 frames", num(a.encS0) + " / " + num(a.encS2));
    Table t("Nodes", {"Id", "Name", "Home ID", "Node", "Sent", "Addressed", "Encrypted", "RSSI", "Last s", "Last command class"});
    for (const ZwNode& n : newest(a.nodes)) {   // sorted newest first by the receiver
        t.row({n.home + "/" + std::to_string(n.id), n.role, n.home, std::to_string(n.id), num(n.sent), num(n.received), num(n.encrypted), fmt("%.0f", n.rssi), secondsSince(a.timeSec, n.lastSec), n.lastCc});
    }
    o.table(t);
    const size_t limit = besideDevices(t);
    Table p("Networks", {"Home ID", "Nodes", "Frames", "Encrypted", "RSSI", "Last s"});
    for (const ZwNetwork& x : newest(a.networks, limit)) p.row({x.home, std::to_string(x.nodes), num(x.frames), num(x.encrypted), fmt("%.0f", x.rssi), secondsSince(a.timeSec, x.lastSec)});
    o.table(p);
    Table l("Frames", {"Time UTC", "From", "To", "Text", "MHz", "Rate", "Home ID", "Type", "Seq", "RSSI"});
    for (const ZwFrame& f : newest(a.log, limit)) {
        l.row({clockUtc(f.wallTime), f.src, f.dst, f.text, fmt("%.2f", f.mhz), zwave::rateName(f.rate), f.home, f.type, std::to_string(f.seq), fmt("%.0f", f.rssi)});
    }
    o.table(l);
}

void loraRaw(Out& o, const LoraRawTelemetry& a) {
    common(o, heard(a.state), a.snrDb, a.levelDb, a.cfoHz, a.blocksOk, a.blocksBad, "Frames ok / CRC bad");
    o.card("Preambles", num(a.preambles));
    o.card("Header failures", num(a.headerBad));
    o.card("Search", fmt("%s, %s", a.cfg.autoSf ? "SF auto" : fmt("SF%d", a.cfg.sf).c_str(), a.cfg.autoBw ? "BW auto" : fmt("%d kHz", a.cfg.bwKhz).c_str()));
    Table t("Frames", {"Id", "Text", "Time UTC", "SF", "BW", "CR", "Len", "CRC", "SNR dB", "RSSI", "Offset kHz", "Payload hex"});
    for (const LrFrame& f : newest(a.log)) {
        t.row({fmt("SF%d %.0f kHz", f.sf, f.bwHz / 1e3), f.ascii, clockUtc(f.wallTime), std::to_string(f.sf), fmt("%.0f kHz", f.bwHz / 1e3), fmt("4/%d", f.cr), std::to_string(f.len),
               !f.hasCrc ? "none" : f.crcOk ? "ok" : "bad", fmt("%.1f", f.snrDb), fmt("%.0f", f.levelDb), fmt("%.1f", f.cfoHz / 1e3), f.hex});
    }
    o.table(t);
}

std::string sigfoxPayload(const SigfoxMessage& m) { return !m.payload.empty() ? m.payload : !m.singleBit ? "(no payload)" : m.bitValue ? "bit 1" : "bit 0"; }

void sigfox(Out& o, const SigfoxModeTelemetry& a) {
    common(o, a.state >= 2 ? "uplinks" : a.state == 1 ? "listening" : "no input", a.snrDb, a.levelDb, a.cfoHz, a.blocksOk, a.blocksBad, "Repetitions ok / failed");
    if (!a.zone.empty()) o.card("Zone", a.zone);
    o.card("Messages", num(a.sf.messages.size()));
    o.card("Carriers", num(a.sf.carriers));
    struct Device { const SigfoxMessage* last; int messages; };
    std::vector<Device> devices;
    for (const SigfoxMessage& m : a.sf.messages) {   // newest first: the first of an id is its last message
        auto it = std::find_if(devices.begin(), devices.end(), [&](const Device& d) { return d.last->id == m.id; });
        if (it == devices.end()) devices.push_back({&m, 1}); else it->messages++;
    }
    Table t("Devices", {"Id", "Name", "Counter", "Payload", "Messages", "RSSI", "Last s"});
    for (const Device& d : newest(devices)) {
        t.row({d.last->id, "", num(d.last->seq), sigfoxPayload(*d.last), std::to_string(d.messages), fmt("%.0f", d.last->levelDb), secondsSinceWall(d.last->wallTime)});
    }
    o.table(t);
    Table l("Messages", {"Time UTC", "From", "To", "Text", "Counter", "Ranks", "Offset kHz", "RSSI", "Rate"});
    for (const SigfoxMessage& m : newest(a.sf.messages, besideDevices(t))) {
        std::string ranks;
        for (int r = 0; r < 3; r++) if (m.rankMask & (1 << r)) ranks = join(ranks, std::to_string(r + 1), " ");
        l.row({clockUtc(m.wallTime), m.id, "", sigfoxPayload(m), num(m.seq), ranks, m.freqs.empty() ? "" : fmt("%+.1f", (m.freqs[0] - (a.dialHz > 0 ? a.dialHz : 0)) / 1e3), fmt("%.0f", m.levelDb), std::to_string(m.baud)});
    }
    o.table(l);
}

void wifiNets(Out& o, const WifiTelemetry& a) {
    common(o, heard(a.state), a.snrDb, a.levelDb, a.cfoHz, a.blocksOk, a.blocksBad, "Frames ok / bad");
    if (a.channel) o.card("Channel", fmt("%d (%s)", a.channel, wifi::bandName(a.band)));
    o.card("Networks", num(a.aps.size()));
    o.card("Beacons", num(a.beacons));
    o.card("Probe responses", num(a.probeResps));
    Table t("Networks", {"Id", "Name", "Band", "Ch", "Width", "Std", "Security", "Vendor", "RSSI", "Beacons", "Interval", "Details", "Last s"});
    for (const WifiAp& x : newest(a.aps)) {
        t.row({x.bssid, x.hidden || x.ssid.empty() ? "(hidden)" : x.ssid, wifi::bandName(x.band), x.channel ? std::to_string(x.channel) : "", fmt("%d MHz", x.widthMhz), x.standard,
               wifi::securityName(x.security, x.enterprise), x.vendor, fmt("%.0f", x.rssi), num(x.beacons), x.interval ? fmt("%d TU", x.interval) : "", x.caps, secondsSince(a.timeSec, x.lastSec)});
    }
    o.table(t);
    Table l("Frames", {"Time UTC", "Ch", "BSSID", "RSSI", "Bytes", "Details"});
    for (const WifiFrameLog& f : newest(a.log, besideDevices(t))) {
        l.row({clockUtc(f.wallTime), f.channel ? std::to_string(f.channel) : "", f.bssid, fmt("%.0f", f.rssi), std::to_string(f.len), f.info});
    }
    o.table(l);
}

void lorawanAll(Out& o, const LorawanTelemetry& a) {
    common(o, heard(a.state), a.snrDb, a.levelDb, a.cfoHz, a.blocksOk, a.blocksBad, "Frames ok / bad");
    o.card("Devices", num(a.devices.size()));
    o.card("Channels in band", fmt("%u of %u", a.channelsInBand, a.channelsListed));
    o.card("Demodulators", std::to_string(a.demodulators));
    o.card("Preambles", num(a.preambles));
    if (!a.note.empty()) o.card("Note", a.note);
    Table t("Devices", {"Id", "Name", "Frames", "Up", "Down", "Joins", "Missed", "FCnt", "FPort", "SF", "RSSI", "SNR dB", "Last", "Last s"});
    for (const LwDevice* d : newestBy(a.devices, [](const LwDevice& x) { return x.lastHeard; })) {
        t.row({d->id, d->devEui, std::to_string(d->packets), std::to_string(d->uplinks), std::to_string(d->downlinks), std::to_string(d->joins), std::to_string(d->missed),
               d->fcnt >= 0 ? std::to_string(d->fcnt) : "", orBlank(d->lastFport), d->fsk ? "FSK" : std::to_string(d->sf), fmt("%.0f", d->lastLevelDb), fmt("%.1f", d->lastSnrDb), d->lastType,
               d->lastHeard >= 0 ? secondsSince(a.timeSec, d->lastHeard) : ""});
    }
    o.table(t);
    const size_t limit = besideDevices(t);
    Table l("Frames", {"Time UTC", "Channel MHz", "SF", "BW", "Type", "DevAddr / EUI", "FCnt", "FPort", "Level dBFS", "SNR dB", "MIC", "MAC commands / payload"});
    for (const LwFrame& f : newest(a.log, limit)) {
        l.row({clockUtc(f.wallTime), fmt("%.3f", f.freqHz / 1e6), f.fsk ? "FSK" : std::to_string(f.sf), f.fsk ? "" : fmt("%.0f", f.bwHz / 1e3), f.type,
               f.hasDevAddr ? fmt("%08X", f.devAddr) : f.devEui ? lorawan::eui(f.devEui) : "", f.hasDevAddr ? std::to_string(f.fcnt) : "", orBlank(f.fport), fmt("%.1f", f.levelDb), fmt("%.1f", f.snrDb),
               f.lorawan && f.mtype != 7 && f.mtype != 1 ? fmt("%08X", f.mic) : "", join(f.mac, f.summary)});
    }
    o.table(l);
    Table c("Channels", {"MHz", "Bandwidth", "SF", "Use", "Decoded", "Preambles", "Frames", "CRC errors"});
    for (const LwChannelInfo& x : newest(a.channels, limit)) {
        c.row({fmt("%.3f", x.freqHz / 1e6), fmt("%.0f kHz", x.bwHz / 1e3), x.fsk ? "FSK DR7" : fmt("%d - %d", x.sfMin, x.sfMax), x.downlinkOnly ? "gateway downlink" : "uplink / both", x.inBand ? "yes" : "no",
               num(x.preambles), num(x.frames), num(x.crcBad)});
    }
    o.table(c);
}

void nrf24(Out& o, const Nrf24Telemetry& a) {
    common(o, a.state >= 2 ? "frames" : a.state == 1 ? "bursts, no frame" : "no signal", a.snrDb, a.levelDb, a.cfoHz, a.blocksOk, a.blocksBad, "Frames / other bursts");
    o.card("Addresses", num(a.devices.size()));
    o.card("Bursts", num(a.bursts));
    o.card("250k / 1M / 2M", num(a.frames250) + " / " + num(a.frames1M) + " / " + num(a.frames2M));
    Table t("Devices", {"Id", "Name", "Bytes", "Rate", "CRC", "Frames", "Last s"});
    for (const Nrf24Device& d : newest(a.devices)) {
        t.row({d.address, "", std::to_string(d.lastPayloadLen), fmt("%d kbit/s", d.rateKbps), fmt("CRC-%d", d.crcBits), num(d.count), secondsSinceWall(d.lastSeen)});
    }
    o.table(t);
    const size_t limit = besideDevices(t);
    Table l("Frames", {"Time UTC", "Rate", "Address", "PID", "CRC", "Length", "Copies", "Payload (hex)", "Text"});
    for (const Nrf24Frame& f : newest(a.frames, limit)) {
        l.row({clockUtc(f.utc), fmt("%d kbit/s", f.rateKbps), f.address, std::to_string(f.pid), fmt("CRC-%d", f.crcBits), std::to_string(f.payloadLen), std::to_string(f.repeats), f.payloadHex, f.text});
    }
    o.table(l);
    Table b("Bursts", {"Time UTC", "Duration us", "SNR dB"});
    for (const Nrf24Burst& x : newest(a.burstLog, limit)) b.row({clockUtc(x.utc), fmt("%.0f", x.durationUs), fmt("%.1f", x.snrDb)});
    o.table(b);
}

void flipperChat(Out& o, const EsubghzTelemetry& a) {
    common(o, a.state >= 2 ? "receiving" : a.state == 1 ? "bursts" : "listening", a.snrDb, a.levelDb, a.cfoHz, a.blocksOk, a.blocksBad, "Packets ok / bad");
    o.card("Messages heard", num(a.messages));
    o.card("Sent", num(a.sent));
    if (a.keyOn) o.card("Decrypted", num(a.decrypted));
    if (a.unreadable) o.card("Unreadable", num(a.unreadable));
    Table t("Messages", {"Time UTC", "From", "To", "Text", "Level", "SNR dB"});
    for (const EsgChatLine& c : newestOfOldestFirst(a.chat)) {
        const std::string text = c.kind <= 1 ? esubghz::displayText(c.text) : c.kind == 2 ? "an encrypted line this key does not open" : c.kind == 3 ? "a repeat of an encrypted line, dropped" : c.hex;
        t.row({clockUtc(c.wallTime), c.dir == 1 ? "OnAir" : "Flipper", "", text, c.dir == 1 ? "" : fmt("%.1f", c.levelDb), c.dir == 1 ? "" : fmt("%.1f", c.snrDb)});
    }
    o.table(t);
    Table p("Packets", {"Time UTC", "Octets", "CRC", "Level", "Offset kHz", "Payload"});
    for (const EsgPacket& x : newest(a.packets)) p.row({clockUtc(x.wallTime), std::to_string(x.len), x.crcOk ? "ok" : "bad", fmt("%.1f", x.levelDb), fmt("%+.1f", x.cfoHz / 1e3), x.hex});
    o.table(p);
}
} // namespace

bool iotCellular(const RxTelemetry& rx, Out& o) {
    switch (rx.standard) {
    case 33: cellTowers(o, rx.cell); return true;
    case 58: nrCells(o, rx.nr); return true;
    case 70: nbiotCells(o, rx.nbiot); return true;
    case 40: gsmr(o, rx.gsmr); return true;
    case 82: lbj(o, rx.lbj); return true;
    case railway::kKlwActiveStandard: railwayLog(o, rx.klw); return true;
    case railway::kTdcsActiveStandard: railwayLog(o, rx.tdcs); return true;
    case 208: ebicab(o, rx.ebicab); return true;
    case 144: bleTrackers(o, rx.bletrk); return true;
    case 66: zigbee(o, rx.zigbee); return true;
    case 71: halowNets(o, rx.halow); return true;
    case 78: antSensors(o, rx.ant); return true;
    case 79: dectBases(o, rx.dect); return true;
    case 85: wisun(o, rx.wisun); return true;
    case 87: wmbusMeters(o, rx.wmbus); return true;
    case 149: nfcTags(o, rx.nfc); return true;
    case 99: zwave(o, rx.zwave); return true;
    case 72: loraRaw(o, rx.loraraw); return true;
    case 154: sigfox(o, rx.sigfoxm); return true;
    case 55: wifiNets(o, rx.wifi); return true;
    case 201: lorawanAll(o, rx.lorawan); return true;
    case 211: nrf24(o, rx.nrf24); return true;
    case 205: flipperChat(o, rx.esubghz); return true;
    default: return false;
    }
}

} // namespace onair::results
