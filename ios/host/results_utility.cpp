// Cards and tables for the two-way networks, HF data and utility modes, tools, KA modes, television and digital radio (mode table groups 0, 1, 5, 10, 11, 12, 13, 15).
// The rows of a log go oldest first and newest last: the Swift pages take the last row as the latest (TwoWayPage) and reverse the tail (ModeResultsPage, HamPage).
// "Services" keeps its broadcast order: BroadcastPage lists it as it comes.
#include "results_kit.h"
#include "dect2/hfbeacon/hfbeacon_list.h"
#include "dect2/isdbs/isdbs.h"
#include "dect2/isdbt/isdbt.h"
#include "dect2/shortwave/shortwave_route.h"
#include <algorithm>
#include <cmath>
#include <cstdarg>
#include <ctime>
#include <map>
#include <string>
#include <vector>

namespace onair::results {
using namespace dect2;

namespace {
constexpr size_t kMaxRows = 200;

std::string fmt(const char* f, ...) {
    char b[512];
    va_list ap; va_start(ap, f); vsnprintf(b, sizeof b, f, ap); va_end(ap);
    return b;
}
std::string count(uint64_t v) { return std::to_string(v); }
std::string pair(uint64_t a, uint64_t b) { return std::to_string(a) + " / " + std::to_string(b); }
std::string yesNo(bool b) { return b ? "yes" : "no"; }
std::string idOrQ(int v) { return v < 0 ? std::string("?") : std::to_string(v); }
std::string orQ(const std::string& s) { return s.empty() ? std::string("?") : s; }
std::string hhmmss(int64_t wall) {
    if (wall <= 0) return "";
    time_t t = (time_t)wall; struct tm tm; gmtime_r(&t, &tm);
    return fmt("%02d:%02d:%02d", tm.tm_hour, tm.tm_min, tm.tm_sec);
}
std::string mhz(double hz) { return hz > 0 ? fmt("%.4f", hz / 1e6) : ""; }
std::string flags(std::initializer_list<std::pair<bool, const char*>> on) {
    std::string s;
    for (const auto& f : on) if (f.first) s += (s.empty() ? "" : " ") + std::string(f.second);
    return s;
}

// The newest kMaxRows of a log, newest last, from a log kept in either order
template <class T>
std::vector<const T*> latest(const std::vector<T>& v, bool newestFirst) {
    const size_t n = std::min(v.size(), kMaxRows);
    std::vector<const T*> out;
    out.reserve(n);
    if (newestFirst) for (size_t i = n; i-- > 0;) out.push_back(&v[i]);
    else for (size_t i = v.size() - n; i < v.size(); i++) out.push_back(&v[i]);
    return out;
}
// The same for a list that is not in time order
template <class T, class Key>
std::vector<const T*> latestBy(const std::vector<T>& v, Key key) {
    std::vector<const T*> out;
    out.reserve(v.size());
    for (const T& x : v) out.push_back(&x);
    std::stable_sort(out.begin(), out.end(), [&](const T* a, const T* b) { return key(*a) < key(*b); });
    if (out.size() > kMaxRows) out.erase(out.begin(), out.end() - kMaxRows);
    return out;
}

void head(Out& o, const std::string& state, double snr, double level, double cfo) {
    o.card("State", state);
    if (snr != 0) o.card("SNR", fmt("%.1f dB", snr));
    if (level > -199) o.card("Level", fmt("%.1f dBFS", level));
    if (cfo != 0) o.card("CFO", fmt("%+.0f Hz", cfo));
}

// The text of a mode as lines (long ones wrapped), for a stream with no log of its own
std::vector<std::string> textLines(const std::string& s) {
    std::vector<std::string> lines;
    size_t p = 0;
    while (p <= s.size()) {
        size_t e = s.find('\n', p);
        if (e == std::string::npos) e = s.size();
        std::string ln = s.substr(p, e - p);
        while (ln.size() > 90) { lines.push_back(ln.substr(0, 90)); ln = ln.substr(90); }
        if (!ln.empty()) lines.push_back(ln);
        p = e + 1;
    }
    if (lines.size() > kMaxRows) lines.erase(lines.begin(), lines.end() - kMaxRows);
    return lines;
}
void textMessages(Out& o, const char* name, const std::string& s) {
    Table t(name, {"Time UTC", "From", "To", "Text"});
    for (const std::string& l : textLines(s)) t.row({"", "", "", l});
    o.table(t);
}
void eventLines(Out& o, const char* name, const std::vector<std::string>& ev, bool newestFirst) {
    Table t(name, {"Event"});
    for (const std::string* e : latest(ev, newestFirst)) t.row({*e});
    o.table(t);
}

// The strongest peaks of a spectrum: local maxima 10 dB over the floor, strongest first
void peakTable(Out& o, const std::vector<float>& db, float floorDb, double firstHz, double binHz, bool absolute) {
    struct Peak { size_t bin; float v; };
    std::vector<Peak> peaks;
    for (size_t i = 1; i + 1 < db.size(); i++)
        if (db[i] > floorDb + 10 && db[i] >= db[i - 1] && db[i] > db[i + 1]) peaks.push_back({i, db[i]});
    std::sort(peaks.begin(), peaks.end(), [](const Peak& a, const Peak& b) { return a.v > b.v; });
    if (peaks.size() > 20) peaks.resize(20);
    Table t("Peaks", {absolute ? "MHz" : "Offset kHz", "Level dBFS", "Over floor dB"});
    for (auto it = peaks.rbegin(); it != peaks.rend(); ++it) {
        const double hz = firstHz + (double)it->bin * binHz;
        t.row({absolute ? fmt("%.4f", hz / 1e6) : fmt("%+.1f", hz / 1e3), fmt("%.1f", it->v), fmt("%.1f", it->v - floorDb)});
    }
    o.table(t);
}

// ---- two-way networks

void tetrapol(Out& o, const TetrapolTelemetry& t) {
    static const char* const st[] = {"no input", "searching", "cell heard"};
    static const char* const verdict[] = {"unknown", "clear", "encrypted"};
    head(o, st[std::clamp(t.state, 0, 2)], t.snrDb, t.levelDb, t.cfoHz);
    o.card("Frames ok / bad", pair(t.blocksOk, t.blocksBad));
    o.card("Frame sync", yesNo(t.synced));
    if (t.band) o.card("Band", t.band == 1 ? "VHF" : "UHF");
    if (t.scramble >= 0) o.card("Scrambling", std::to_string(t.scramble));
    o.card("Channel spacing", fmt("%.1f kHz", t.spacingHz / 1e3));
    o.card("Voice frames / decoded", pair(t.voiceFrames, t.voiceDecoded));
    if (t.callVerdict >= 0) o.card("Call now", verdict[std::clamp(t.callVerdict, 0, 2)]);
    o.card("Voice decoder", t.codecReady ? "available" : "not installed (silent)");
    if (!t.voiceStatus.empty()) o.card("Voice", t.voiceStatus);
    // The signalling on a traffic channel gives no unit or group numbers here, so the two ends stay unknown
    Table c("Calls", {"Time UTC", "Source", "Target", "Seconds", "Encryption", "Voice frames", "Decoded", "Damaged", "Note"});
    for (const TetrapolCall* x : latestBy(t.calls, [](const TetrapolCall& v) { return v.startSec; }))
        c.row({hhmmss(x->startWall), "?", "?", fmt("%.1f", x->lastSec - x->startSec), verdict[std::clamp(x->verdict, 0, 2)], count(x->voiceFrames), count(x->decoded), count(x->damaged), x->active ? "on air" : ""});
    o.table(c);
    // heard counts announcements, several per call: it is not a number of calls. Group numbers are only known for clear calls.
    Table g("Talkgroups", {"Talkgroup", "Heard", "Channel", "Encryption", "Last UTC"});
    for (const TetrapolActivation* a : latestBy(t.activations, [](const TetrapolActivation& v) { return v.lastSec; }))
        if (a->groupId >= 0) g.row({std::to_string(a->groupId), count(a->heard), a->channelId >= 0 ? std::to_string(a->channelId) : "", verdict[std::clamp(a->verdict, 0, 2)], hhmmss(a->lastWall)});
    o.table(g);
    Table s("Cells", {"MHz", "System", "Cell", "Area", "Scrambling", "Level dBFS", "SNR dB", "Frames ok", "Frames bad", "Last UTC"});
    for (const TetrapolCell* x : latestBy(t.cells, [](const TetrapolCell& v) { return v.lastSec; }))
        s.row({mhz(x->freqHz), x->systemId >= 0 ? std::to_string(x->systemId) : "", x->cellId >= 0 ? std::to_string(x->cellId) : "", x->locArea >= 0 ? std::to_string(x->locArea) : "",
               x->scramble >= 0 ? std::to_string(x->scramble) : "", fmt("%.1f", x->levelDb), fmt("%.1f", x->snrDb), count(x->framesOk), count(x->framesBad), hhmmss(x->lastWall)});
    o.table(s);
    Table e("Events", {"Time UTC", "Event"});
    for (const TetrapolEvent* x : latestBy(t.events, [](const TetrapolEvent& v) { return v.sec; })) e.row({hhmmss(x->wallTime), x->text});
    o.table(e);
}

void tones(Out& o, const TonesTelemetry& t) {
    static const char* const st[] = {"nothing", "audio present", "decoding"};
    head(o, st[std::clamp(t.state, 0, 2)], t.snrDb, t.levelDb, t.cfoHz);
    o.card("Detections", count(t.blocksOk));
    if (t.audioDb > -199) o.card("Audio", fmt("%.1f dB", t.audioDb));
    if (t.ctcssIdx >= 0) o.card("CTCSS", fmt("%.1f Hz", t.ctcssHz));
    if (t.dcsCode >= 0) o.card("DCS", fmt("D%03d%c", t.dcsCode, t.dcsInv ? 'I' : 'N') + (t.dcsAlias.empty() ? "" : " (also " + t.dcsAlias + ")"));
    if (t.toneHz > 0) o.card("Strongest tone", fmt("%.1f Hz", t.toneHz));
    if (!t.dtmfString.empty()) o.card("DTMF", t.dtmfString);
    o.card("Gate", t.gateOpen ? "open" : "closed");
    for (int k = 0; k < TkKinds; k++) if (t.counts[k]) o.card(toneKindName(k), std::to_string(t.counts[k]));
    Table e("Detections", {"Time UTC", "Kind", "Code", "Detail", "Seconds", "Level dB", "Note"});
    for (const ToneEvent* x : latest(t.events, true))
        e.row({hhmmss(x->wall), toneKindName(x->kind), x->text, x->detail, fmt("%.1f", x->durSec), x->levelDb > -199 ? fmt("%.1f", x->levelDb) : "", x->active ? "present" : ""});
    o.table(e);
}

void mpt1327(Out& o, const MptTelemetry& t) {
    head(o, t.state >= 2 ? "locked" : t.state == 1 ? "searching" : "no input", t.snrDb, t.levelDb, t.cfoHz);
    o.card("Codewords ok / bad", pair(t.good, t.bad));
    o.card("Messages", count(t.messages));
    if (t.sysId >= 0) o.card("System", fmt("%04X", t.sysId));
    o.card("Sync check", t.syncTolerant ? "tolerant" : "standard");
    o.card("Channels seen", std::to_string(t.channels.size()));
    // Control messages have no length: Seconds stays empty and Time s is when the message came, since the receiver started
    Table m("Messages", {"Time s", "Type", "Source", "Target", "Seconds", "Channel", "Note"});
    for (const MptMessageRow* x : latest(t.rows, false))
        m.row({fmt("%.1f", x->t), x->type, orQ(x->caller), orQ(x->called), "", x->channel >= 0 ? std::to_string(x->channel) : "", x->detail});
    o.table(m);
    Table c("Channels", {"Channel", "Control", "Seen", "Last s", "Last target", "Last source"});
    for (const MptChannelRow* x : latestBy(t.channels, [](const MptChannelRow& v) { return v.lastT; }))
        c.row({std::to_string(x->channel), x->controlChannel ? "yes" : "", std::to_string(x->count), fmt("%.1f", x->lastT), x->called, x->caller});
    o.table(c);
}

void ltr(Out& o, const LtrTelemetry& t) {
    head(o, t.state >= 2 ? (t.locked ? "locked" : "words heard") : t.state == 1 ? "listening" : "no input", t.snrDb, t.levelDb, t.cfoHz);
    o.card("Words ok / bad", pair(t.blocksOk, t.blocksBad));
    o.card("Syncs", count(t.syncs));
    if (t.area >= 0) o.card("Area", std::to_string(t.area));
    if (t.deviationHz > 0) o.card("Data deviation", fmt("%.0f Hz", t.deviationHz));
    o.card("Repeaters", std::to_string(t.repeaters.size()));
    // LTR sends no unit number. A call is the words of one talkgroup with no gap over kGap, so calls and their seconds are counted from the word log (the last 400 words).
    constexpr double kGap = 3;
    struct Call { std::string tg; int64_t wall; double first, last; int gotoCh, home; };
    std::vector<Call> calls;
    std::map<std::string, size_t> open;
    std::map<std::string, int> perGroup;
    for (auto it = t.messages.rbegin(); it != t.messages.rend(); ++it) {
        if (!it->kind.empty() || it->talkgroup.empty()) continue;
        auto f = open.find(it->talkgroup);
        if (f != open.end() && it->timeSec - calls[f->second].last <= kGap) { calls[f->second].last = it->timeSec; continue; }
        open[it->talkgroup] = calls.size();
        perGroup[it->talkgroup]++;
        calls.push_back({it->talkgroup, it->wallTime, it->timeSec, it->timeSec, it->gotoCh, it->home});
    }
    Table c("Calls", {"Time UTC", "Source", "Target", "Seconds", "Repeater", "Home", "Note"});
    for (size_t i = calls.size() > kMaxRows ? calls.size() - kMaxRows : 0; i < calls.size(); i++) {
        const Call& x = calls[i];
        c.row({hhmmss(x.wall), "?", x.tg, fmt("%.1f", x.last - x.first), std::to_string(x.gotoCh), std::to_string(x.home), ""});
    }
    o.table(c);
    Table g("Talkgroups", {"Talkgroup", "Calls"});
    for (const auto& kv : perGroup) g.row({kv.first, std::to_string(kv.second)});
    o.table(g);
    Table r("Repeaters", {"Repeater", "As goto", "As home", "As free"});
    for (const LtrRepeater& x : t.repeaters) r.row({std::to_string(x.ch), count(x.asGoto), count(x.asHome), count(x.asFree)});
    o.table(r);
    Table w("Words", {"Time UTC", "Word", "Talkgroup", "Goto", "Home", "Id", "Free"});
    for (const LtrMessage* x : latest(t.messages, true))
        w.row({hhmmss(x->wallTime), x->kind.empty() ? "call" : x->kind, x->talkgroup, std::to_string(x->gotoCh), std::to_string(x->home), std::to_string(x->id), std::to_string(x->freeCh)});
    o.table(w);
}

void edacs(Out& o, const EdacsTelemetry& t) {
    head(o, t.state >= 2 ? (t.locked ? "locked" : "frames heard") : t.state == 1 ? "listening" : "no input", t.snrDb, t.levelDb, t.cfoHz);
    o.card("Frames ok / bad", pair(t.blocksOk, t.blocksBad));
    if (t.siteValid) o.card("Site", std::to_string(t.siteId) + (t.systemId >= 0 ? " (area " + std::to_string(t.systemId) + ")" : ""));
    if (t.controlLcn >= 0) o.card("Control LCN", std::to_string(t.controlLcn));
    if (t.nChannels >= 0) o.card("Highest LCN", std::to_string(t.nChannels));
    o.card("Messages known", pair(t.messagesKnown, t.messages));
    if (t.followLcn) o.card("Listening to LCN", std::to_string(t.followLcn));
    if (!t.note.empty()) o.card("Voice", t.note);
    Table c("Calls", {"Time UTC", "Source", "Target", "Seconds", "LCN", "MHz", "Flags", "Note"});
    for (const EdacsCall* x : latestBy(t.calls, [](const EdacsCall& v) { return v.startSec; }))
        c.row({hhmmss(x->wallTime), idOrQ(x->lid), (x->group && x->gid >= 0 ? "TG " : "") + idOrQ(x->gid), fmt("%.1f", x->durSec), std::to_string(x->lcn), mhz(x->freqHz),
               flags({{x->active, "ON AIR"}, {x->emergency, "EMERG"}, {x->digital, "digital"}, {x->followed, "listening"}}), x->fromActivity ? "carrier only, no assignment heard" : ""});
    o.table(c);
    Table g("Talkgroups", {"Talkgroup", "Calls", "Last unit", "LCN", "MHz", "Last UTC", "Flags"});
    for (const EdacsTalkgroup* x : latest(t.talkgroups, true))
        g.row({std::to_string(x->gid), std::to_string(x->calls), idOrQ(x->lastLid), x->lastLcn ? std::to_string(x->lastLcn) : "", mhz(x->lastFreqHz), hhmmss(x->lastWall), x->active ? "ON AIR" : ""});
    o.table(g);
    Table l("Voice channels", {"LCN", "MHz", "Level dBFS", "Floor dBFS", "Active"});
    int n = 0;
    for (const EdacsChannelActivity& x : t.channels) {
        if (++n > (int)kMaxRows) break;
        l.row({std::to_string(x.lcn), mhz(x.freqHz), x.inCapture ? fmt("%.1f", x.levelDb) : "", x.inCapture ? fmt("%.1f", x.floorDb) : "", x.active ? "yes" : ""});
    }
    o.table(l);
    Table f("Frames", {"Time UTC", "Meaning", "Good"});
    for (const EdacsFrame* x : latest(t.frames, true)) f.row({hhmmss(x->wallTime), x->text, yesNo(x->good)});
    o.table(f);
}

void p25p2(Out& o, const P25p2Telemetry& t) {
    head(o, t.state >= 2 ? "call on air" : t.state == 1 ? "locked" : "searching", t.snrDb, t.levelDb, t.cfoHz);
    o.card("MAC PDUs ok / bad", pair(t.blocksOk, t.blocksBad));
    if (t.nac >= 0) o.card("NAC", fmt("%03X", t.nac));
    if (t.site.valid) o.card("System / site", fmt("WACN %05X  sys %03X  site %d-%d", std::max(t.site.wacn, 0), std::max(t.site.sysId, 0), t.site.rfss, t.site.site));
    o.card("Voice frames / decoded", pair(t.voiceFrames, t.voiceDecoded));
    o.card("Encrypted, skipped", count(t.encryptedSkipped));
    o.card("Voice decoder", t.codec ? "available" : "not installed (silent)");
    Table c("Calls", {"Slot", "Kind", "Source", "Target", "Seconds", "Frames", "Freq MHz", "Flags", "Note"});
    auto add = [&](const P25p2Call& x) {
        c.row({x.slot ? std::to_string(x.slot) : "", x.kind == 1 ? "Grant" : "Voice", p25Id(x.src), (x.group ? "TG " : "") + p25Id(x.dst), fmt("%.1f", x.durSec), std::to_string(x.voiceFrames), mhz(x.freqHz),
               flags({{x.active, "ON AIR"}, {x.emergency, "EMERG"}, {x.encrypted, "ENC"}, {x.lateEntry, "late"}}), x.text});
    };
    for (const P25p2Call* x : latest(t.log, true)) add(*x);
    for (const P25p2Call& x : t.now) if (x.active) add(x);
    o.table(c);
    Table g("Talkgroups", {"Talkgroup", "Calls", "Grants", "Last unit", "Freq MHz", "Flags"});
    for (const P25Talkgroup* x : latest(t.talkgroups, true))
        g.row({std::to_string(x->tg), std::to_string(x->calls), std::to_string(x->grants), p25Id(x->lastSrc), mhz(x->lastFreqHz), flags({{x->active, "ON AIR"}, {x->encrypted, "ENC"}, {x->emergency, "EMERG"}})});
    o.table(g);
    eventLines(o, "Control messages", t.events, true);
}

void m17(Out& o, const M17Telemetry& t) {
    head(o, t.state >= 2 ? "receiving" : t.state == 1 ? "frames heard" : "searching", t.snrDb, t.levelDb, t.cfoHz);
    o.card("Frames ok / bad", pair(t.blocksOk, t.blocksBad));
    o.card("BER", fmt("%.2f %%", t.berPct));
    if (t.deviationHz > 0) o.card("Deviation", fmt("%.0f Hz", t.deviationHz));
    o.card("LSF ok / bad", pair(t.lsfOk, t.lsfBad));
    o.card("Packets ok / bad", pair(t.packetsOk, t.packetsBad));
    o.card("Voice decoder", t.codec2 ? "Codec 2" : "not installed (silent)");
    Table c("Calls", {"Time UTC", "Source", "Target", "Seconds", "Type", "CAN", "Encryption", "BER %", "Frames", "Note"});
    auto add = [&](const M17Transmission& x) {
        c.row({hhmmss(x.wallTime), orQ(x.src), orQ(x.dst), fmt("%.1f", x.durSec), x.type, x.can >= 0 ? std::to_string(x.can) : "", x.enc, fmt("%.1f", x.berPct), std::to_string(x.frames), x.text.empty() ? x.data : x.text});
    };
    for (const M17Transmission* x : latest(t.log, true)) add(*x);
    if (t.now.active) add(t.now);
    o.table(c);
    Table m("Messages", {"Time UTC", "From", "To", "Text"});
    for (const M17Message* x : latest(t.messages, true)) m.row({hhmmss(x->wallTime), x->src, x->dst, x->text});
    o.table(m);
    Table p("Positions", {"Time UTC", "From", "Lat", "Lon", "Alt m", "km/h"});
    for (const M17Position* x : latest(t.positions, true))
        p.row({hhmmss(x->wallTime), x->src, fmt("%.5f", x->lat), fmt("%.5f", x->lon), x->altValid ? fmt("%.0f", x->altM) : "", x->velValid ? fmt("%.0f", x->speedKmh) : ""});
    o.table(p);
}

void fusion(Out& o, const FusionTelemetry& t) {
    static const char* const dt[] = {"V/D mode 1", "data FR", "V/D mode 2", "voice FR"};
    const bool hasType = t.dataType >= 0 && t.dataType < 4;
    head(o, t.state >= 2 ? "receiving" : t.state == 1 ? "listening" : "no input", t.snrDb, t.levelDb, t.cfoHz);
    o.card("Frames ok / bad", pair(t.blocksOk, t.blocksBad));
    if (hasType) o.card("Data type", dt[t.dataType]);
    if (t.callMode >= 0) o.card("Call mode", t.callMode == 3 ? "individual" : "group / CQ");
    if (t.routing >= 0) o.card("Routing", t.routing == 0 ? "direct" : t.routing == 1 ? "downlink, uplink idle" : "downlink, uplink busy");
    if (t.squelch > 0) o.card("Squelch code", std::to_string(t.squelch));
    if (t.voip == 1) o.card("Route", "via internet");
    o.card("Voice sub-frames / decoded", pair(t.voiceSubFrames, t.voiceDecoded));
    o.card("Voice decoder", t.codecReady ? "available" : t.codecText.empty() ? "not installed (silent)" : t.codecText);
    // The receiver keeps no log: only the transmission being received, or the last one
    if (!t.src.empty() || !t.dest.empty()) {
        Table c("Calls", {"Source", "Target", "Seconds", "Type", "Downlink", "Uplink", "Note"});
        c.row({orQ(t.src), orQ(t.dest), "", hasType ? dt[t.dataType] : "", t.down, t.up, t.slowText});
        o.table(c);
    }
}

// ---- HF data

void textStream(Out& o, const std::vector<Kbd33Msg>& msgs, const std::vector<Kbd33Line>& lines) {
    // Signal seconds, not a clock: Time UTC stays empty
    Table m("Messages", {"Time UTC", "From", "To", "Text", "Signal s"});
    for (const Kbd33Msg* x : latest(msgs, false)) m.row({"", x->from, x->to, x->text, fmt("%.0f", x->timeSec)});
    o.table(m);
    Table t("Text", {"Time UTC", "From", "To", "Text", "Signal s"});
    for (const Kbd33Line* x : latest(lines, false)) t.row({"", "", "", x->text, fmt("%.0f", x->timeSec)});
    o.table(t);
}

void kbd33(Out& o, const Kbd33Telemetry& t) {
    head(o, t.state >= 2 ? "decoding" : "searching", t.snrDb, t.levelDb, t.cfoHz);
    o.card("Characters", count(t.chars));
    if (t.baud > 0) o.card("Speed", fmt("%.2f baud", t.baud));
    if (t.bandHz > 0) o.card("Band", fmt("%.0f Hz", t.bandHz));
    o.card("Tone quality", fmt("%.2f", t.quality));
    if (!t.calls.empty()) o.card("Calls heard", std::to_string(t.calls.size()));
    textStream(o, t.msgs, t.lines);
}

void mt63(Out& o, const Mt63Telemetry& t) {
    head(o, t.state >= 2 ? "decoding" : t.state == 1 ? "synchronising" : "searching", t.snrDb, t.levelDb, t.cfoHz);
    o.card("Characters", count(t.chars));
    if (t.bandwidth) o.card("Mode", fmt("MT63-%d, %s", t.bandwidth, mt63InterleaveName(t.interleave)));
    if (t.centreHz > 0) o.card("Centre", fmt("%.0f Hz", t.centreHz));
    o.card("Quality", fmt("%.1f", t.quality));
    if (!t.calls.empty()) o.card("Calls heard", std::to_string(t.calls.size()));
    Table m("Messages", {"Time UTC", "From", "To", "Text", "Signal s"});
    for (const Mt63Line* x : latest(t.lines, false)) m.row({"", "", "", x->text, fmt("%.0f", x->timeSec)});
    o.table(m);
}

void sitor(Out& o, const SitorTelemetry& t) {
    head(o, t.state >= 2 ? "locked, SITOR-B" : t.state == 1 ? "FSK found" : "no FSK", t.snrDb, -200, t.cfoHz);
    o.card("Code words ok / bad", pair(t.blocksOk, t.blocksBad));
    o.card("Characters", count(t.chars));
    if (t.shiftHz > 0) o.card("Shift", fmt("%.0f Hz", t.shiftHz));
    if (t.baud > 0) o.card("Baud", fmt("%.1f", t.baud));
    if (t.inverted) o.card("Tones", "swapped");
    textMessages(o, "Messages", t.text);
}

void ardop(Out& o, const ArdopTelemetry& t) {
    head(o, t.state >= 2 ? "frames decoded" : t.state == 1 ? "reading a frame" : "no signal", t.snrDb, t.levelDb, t.cfoHz);
    o.card("Frames ok / unreadable", pair(t.blocksOk, t.blocksBad));
    o.card("Leaders", count(t.leaders));
    o.card("Data ok / bad", pair(t.dataOk, t.dataBad));
    o.card("Control frames", count(t.controlFrames));
    o.card("Stations", std::to_string(t.stations.size()));
    Table f("Frames", {"Time UTC", "From", "To", "Text", "Frame", "Kind", "Check", "SNR dB", "Quality"});
    for (const ArdopFrameLog* x : latest(t.frames, true))
        f.row({hhmmss(x->utc), x->from, x->to, x->text, x->name, x->kind, x->bodyRead ? (x->bodyOk ? "ok" : "bad") : "", fmt("%.0f", x->toneSnrDb), x->quality >= 0 ? std::to_string(x->quality) : ""});
    o.table(f);
    Table s("Stations", {"Call", "Locator", "Frames", "Last frame", "Called", "Last UTC"});
    for (const ArdopStation* x : latest(t.stations, true)) s.row({x->call, x->locator, count(x->count), x->last, x->heardTo, hhmmss(x->lastSeen)});
    o.table(s);
}

void roshf(Out& o, const RoshfTelemetry& t) {
    head(o, t.state >= 2 ? "ROS detected" : t.state == 1 ? "signal of the right width" : "no signal", t.snrDb, t.levelDb, t.cfoHz);
    if (t.state == 2) {
        o.card("Signal", t.name + (t.weak ? " (perhaps)" : ""));
        o.card("Tones", fmt("%.0f - %.0f Hz", t.loHz, t.hiHz));
        o.card("Baud", fmt("%.1f", t.baud));
        o.card("Spacing", fmt("%.1f Hz", t.spacingHz));
    }
    o.card("Detections", count(t.blocksOk));
    if (!t.textStatus.empty()) o.card("Text", t.textStatus);
    Table e("Detections", {"Time UTC", "Signal", "Tones Hz", "Baud", "Spacing Hz", "Score", "Why"});
    for (const RoshfEvent* x : latest(t.events, true))
        e.row({hhmmss(x->utc), x->name + (x->weak ? " (perhaps)" : ""), fmt("%.0f - %.0f", x->loHz, x->hiHz), fmt("%.1f", x->baud), fmt("%.1f", x->spacingHz), fmt("%.2f", x->score), x->why});
    o.table(e);
}

void pactor(Out& o, const PactorTelemetry& t) {
    head(o, t.state >= 2 ? "packets decoded" : t.state == 1 ? "tone pair or burst" : "no signal", t.snrDb, t.levelDb, t.cfoHz);
    o.card("Packets ok / bad", pair(t.blocksOk, t.blocksBad));
    o.card("Link", t.fecMode ? "unproto / FEC" : "ARQ");
    if (t.pairLowHz > 0) o.card("Tone pair", fmt("%.0f / %.0f Hz", t.pairLowHz, t.pairLowHz + 200));
    o.card("100 / 200 baud packets", pair(t.slowPackets, t.fastPackets));
    o.card("Connects", count(t.connects));
    o.card("Repeats", count(t.repeats));
    // call is the station called in a connect packet; the sender is known only as side 1 or 2 of the link
    Table f("Frames", {"Time UTC", "From", "To", "Text", "Kind", "Baud", "CRC", "SNR dB"});
    for (const PactorFrameLog* x : latest(t.frames, true))
        f.row({hhmmss(x->utc), fmt("side %d", x->sender), x->call, x->text, x->kind, std::to_string(x->baud), x->crcOk ? "ok" : "bad", fmt("%.0f", x->snrDb)});
    o.table(f);
    Table s("Stations", {"Call", "Packets", "How", "Last UTC"});
    for (const PactorStation* x : latestBy(t.stations, [](const PactorStation& v) { return v.lastSeen; })) s.row({x->call, count(x->count), x->how, hhmmss(x->lastSeen)});
    o.table(s);
}

void pactorHf(Out& o, const PactorHfTelemetry& t) {
    head(o, t.state >= 2 ? "frame structure found" : t.state == 1 ? "carriers found" : "no signal", t.snrDb, t.levelDb, t.cfoHz);
    o.card("Looking for", pactorHfName(t.wanted));
    if (t.variant) o.card("Found", pactorHfName(t.variant));
    if (t.nCarriers) o.card("Carriers", std::to_string(t.nCarriers));
    if (t.baud > 0) o.card("Baud", fmt("%.1f", t.baud));
    if (t.bwHz > 0) o.card("Bandwidth", fmt("%.0f Hz", t.bwHz));
    if (t.framePeriodSec > 0) o.card("Frame", fmt("%.2f s", t.framePeriodSec));
    o.card("Frame copies", count(t.blocksOk));
    o.card("Content", "signal analysis only, nothing is decoded");
    if (!t.note.empty()) o.card("Note", t.note);
    Table e("Events", {"Time UTC", "Event"});
    for (const PactorHfEvent* x : latest(t.events, true)) e.row({hhmmss(x->utc), x->text});
    o.table(e);
}

void datawell(Out& o, const DatawellTelemetry& t) {
    head(o, t.state >= 2 ? "symbols locked" : t.state == 1 ? "FSK-like signal" : "listening", t.snrDb, t.levelDb, t.cfoHz);
    if (t.freqMhz > 0) o.card("Frequency", fmt("%.4f MHz", t.freqMhz));
    if (!t.channel.empty()) o.card("Channel", t.channel);
    if (!t.format.empty()) o.card("Format (a guess)", t.format);
    if (t.bwHz > 0) o.card("Bandwidth", fmt("%.0f Hz", t.bwHz));
    if (t.baud > 0) o.card("Baud", fmt("%.2f", t.baud));
    if (t.periodBits) o.card("Frame", fmt("%d bits, %.2f s", t.periodBits, t.periodSec));
    if (t.hxvLocked) o.card("HXV vectors clean / repaired / lost", std::to_string(t.hxvClean) + " / " + std::to_string(t.hxvRepaired) + " / " + std::to_string(t.hxvLost));
    const DwSystem& s = t.sys;
    if (s.have[1]) o.card("Wave height Hs", fmt("%.2f m", s.hs));
    if (s.have[2]) o.card("Period Tz", fmt("%.1f s", s.tz));
    if (s.have[3]) o.card("Peak density", fmt("%.2f m2/Hz", s.psdMax));
    if (s.have[5]) o.card("Water temperature", fmt("%.2f C", s.tw));
    if (s.have[6]) o.card("Battery", std::to_string(s.battery));
    if (s.have[0]) o.card("GPS fix", yesNo(s.gpsFix));
    if (s.havePos) o.card("Position", fmt("%.5f, %.5f", s.lat, s.lon));
    Table d("Directional spectrum", {"Hz", "Direction deg", "Spread deg", "PSD"});
    for (int i = 0; i < t.specCount && i < 64; i++)
        if (t.spec[i].valid) d.row({fmt("%.3f", t.spec[i].hz), fmt("%.0f", t.spec[i].dirDeg), fmt("%.0f", t.spec[i].spreadDeg), fmt("%.3f", t.spec[i].psd)});
    o.table(d);
    Table f("Frames", {"Time UTC", "CRC attempt", "Bytes"});
    for (const DwFrame* x : latest(t.frames, true)) f.row({hhmmss(x->wall), x->crcOk ? "fits" : "no", x->hex});
    o.table(f);
}

void codar(Out& o, const CodarTelemetry& t) {
    head(o, t.state >= 1 ? "sweeps heard" : "nothing heard", t.snrDb, t.levelDb, t.cfoHz);
    o.card("Sweeps accepted / rejected", pair(t.blocksOk, t.blocksBad));
    o.card("Radars", std::to_string(t.stations.size()));
    if (!t.bandNow.empty()) o.card("Band", t.bandNow);
    Table s("Radars", {"Radar", "MHz", "Band", "Sweep kHz", "kHz/s", "Period s", "Sweeps", "SNR dB", "Best dB", "ID (unverified)", "Guess", "Last UTC"});
    for (const CdStation* x : latest(t.stations, true))
        s.row({std::to_string(x->id), x->centreMhz > 0 ? fmt("%.3f", x->centreMhz) : "", x->band, fmt("%.1f", x->bwKhz), fmt("%.1f", x->rateKhzS), x->periodSec > 0 ? fmt("%.3f", x->periodSec) : "",
               count(x->sweeps), fmt("%.1f", x->snrDb), fmt("%.1f", x->snrMax), x->callsign, x->hint, hhmmss(x->lastWall)});
    o.table(s);
    Table e("Heard", {"Time UTC", "Radar", "Band", "MHz", "SNR dB"});
    for (const CdEvent* x : latest(t.events, true)) e.row({hhmmss(x->wall), std::to_string(x->station), x->band, x->centreMhz > 0 ? fmt("%.3f", x->centreMhz) : "", fmt("%.1f", x->snrDb)});
    o.table(e);
}

void shortwave(Out& o, const ShortwaveTelemetry& t) {
    static const char* const kDemod[] = {"NFM", "WFM", "AM", "USB", "LSB", "CW"};
    static const char* const st[] = {"searching", "signal found", "decoding"};
    const int demod = t.general.demod;
    head(o, t.dataValid ? "decoding" : t.state >= 1 ? "listening" : "no input", t.snrDb, t.levelDb, t.cfoHz);
    if (demod >= 0 && demod < 6) o.card("Demodulator", kDemod[demod]);
    o.card("Squelch", t.general.squelchOpen ? "open" : "closed");
    if (t.general.noiseDb > -199) o.card("Noise", fmt("%.1f dBFS", t.general.noiseDb));
    auto decName = [](int id) { return id >= 0 && id < swr::kDecCount ? std::string(swr::decoderInfo((swr::Dec)id).name) : std::string(); };
    if (t.detected >= 0) o.card("Identified", decName(t.detected) + fmt(" (%.0f %%)", t.detectedConfidence * 100));
    if (t.autoPhase == 1) o.card("Auto", fmt("trying decoders, %.0f s", t.autoSec));
    else if (t.autoPhase == 2) o.card("Auto", t.autoPick >= 0 ? decName(t.autoPick) : "nothing decoded");
    Table d("Decoders", {"Decoder", "State", "Output", "Status", "Note", "Text"});
    int n = 0;
    for (const SwDecoderStatus& x : t.decoders) {
        if (++n > (int)kMaxRows) break;
        const std::vector<std::string> lines = textLines(x.text);
        d.row({decName(x.id), st[std::clamp(x.state, 0, 2)], count(x.chars), x.status, x.note, lines.empty() ? "" : lines.back()});
    }
    o.table(d);
}

void ale(Out& o, const AleTelemetry& t) {
    head(o, t.state >= 2 ? "in word sync" : t.state == 1 ? "searching" : "nothing yet", t.snrDb, t.levelDb, t.cfoHz);
    o.card("Words ok / missed", pair(t.blocksOk, t.blocksBad));
    o.card("Calls", std::to_string(t.events.size()));
    o.card("Stations", std::to_string(t.stations.size()));
    if (t.dialHz > 0) o.card("Dial", fmt("%.3f MHz", t.dialHz / 1e6));
    Table e("Calls", {"Time UTC", "From", "To", "Text", "Type", "Command", "SNR dB", "BER", "MHz"});
    for (const AleEvent* x : latest(t.events, false))
        e.row({hhmmss((int64_t)x->utc), x->from, x->to, x->amd, x->type + (x->tis ? " TIS" : " TWS"), x->cmd, fmt("%.0f", x->snrDb), fmt("%.3f", x->ber), x->dialHz > 0 ? fmt("%.3f", x->dialHz / 1e6) : ""});
    o.table(e);
    Table s("Stations", {"Address", "Heard", "Last", "SNR dB", "BER", "MHz", "Last UTC"});
    for (const AleStation* x : latest(t.stations, true))
        s.row({x->address, std::to_string(x->count), x->lastType, fmt("%.0f", x->snrDb), fmt("%.3f", x->ber), x->lastDialHz > 0 ? fmt("%.3f", x->lastDialHz / 1e6) : "", hhmmss((int64_t)x->lastUtc)});
    o.table(s);
}

void milhf(Out& o, const MilhfTelemetry& t) {
    const milhf::Features& f = t.res.f;
    head(o, t.state >= 2 ? "analysed" : t.state == 1 ? "collecting audio" : "no input", f.signal ? f.snrDb : t.snrDb, t.levelDb, t.cfoHz);
    o.card("Content", "identification only, nothing is decoded");
    o.card("Signal", yesNo(f.signal));
    if (f.signal) {
        o.card("Band", fmt("%.0f - %.0f Hz", f.loHz, f.hiHz));
        if (f.baudHz > 0) o.card("Baud", fmt("%.1f", f.baudHz));
        if (f.nTones > 0) o.card("Tones", std::to_string(f.nTones));
        if (f.toneSpacingHz > 0) o.card("Tone spacing", fmt("%.1f Hz", f.toneSpacingHz));
        if (f.shiftHz > 0) o.card("Shift", fmt("%.0f Hz", f.shiftHz));
    }
    Table c("Candidates", {"Waveform", "Estimate %", "Basis", "Note"});
    for (auto it = t.res.cands.rbegin(); it != t.res.cands.rend(); ++it) c.row({it->name, fmt("%.0f", it->conf * 100), it->basis, it->note});
    o.table(c);
}

void hfBeacons(Out& o, const HfbTelemetry& t) {
    o.card("State", t.state >= 1 ? "listening" : "waiting for samples");
    o.card("Heard now", std::to_string(t.heardNow));
    o.card("Channels watched", std::to_string(t.channels));
    if (t.powerDb > -199) o.card("Level", fmt("%.1f dBFS", t.powerDb));
    if (!t.clockValid) o.card("Clock", "not the computer's: NCDXF slots are not attributed");
    Table b("Bands", {"Band", "Beacons", "In capture", "Heard", "Farthest km"});
    for (const HfbBand& x : t.bands) b.row({x.name, std::to_string(x.total), std::to_string(x.inSpan), std::to_string(x.heard), std::isnan(x.bestKm) ? "" : fmt("%.0f", x.bestKm)});
    o.table(b);
    // The receiver's list is not in the telemetry. It is the default list unless the user edited it: only a list of the same length is taken to match.
    static const std::vector<hfb::Beacon> list = hfb::defaultBeacons();
    const bool named = list.size() == t.beacons.size();
    std::vector<size_t> order;
    for (size_t i = 0; i < t.beacons.size(); i++) if (t.beacons[i].lastHeard > 0) order.push_back(i);
    std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b2) { return t.beacons[a].lastHeard < t.beacons[b2].lastHeard; });
    if (order.size() > kMaxRows) order.erase(order.begin(), order.end() - kMaxRows);
    Table h("Beacons heard", {"Beacon", "kHz", "Identity", "SNR dB", "Best 1 h", "Best 24 h", "km", "Last UTC", "Note"});
    for (size_t i : order) {
        const HfbState& s = t.beacons[i];
        auto db = [](float v) { return std::isnan(v) ? std::string() : fmt("%.0f", v); };
        h.row({named ? list[i].name : fmt("Beacon %zu", i + 1), named ? fmt("%.1f", list[i].khz) : "", s.conf >= 2 ? "confirmed" : s.conf == 1 ? "energy only" : "", db(s.snr), db(s.best1h), db(s.best24h),
               std::isnan(s.distKm) ? "" : fmt("%.0f", s.distKm), hhmmss((int64_t)s.lastHeard), s.note});
    }
    o.table(h);
}

// ---- tools

void workbench(Out& o, const WbTelemetry& t) {
    o.card("State", t.state >= 1 ? "samples arriving" : "no samples");
    if (t.levelDb > -199) o.card("Level", fmt("%.1f dBFS", t.levelDb));
    if (t.inputRate > 0) o.card("Sample rate", fmt("%.3f Msps", t.inputRate / 1e6));
    o.card("Analysis", "works on recordings: the live input is only a level meter");
}

void spectrumExplorer(Out& o, const SpecxTelemetry& t) {
    o.card("State", t.state >= 1 ? "showing the spectrum" : "waiting for samples");
    if (t.powerDb > -199) o.card("Input power", fmt("%.1f dBFS", t.powerDb));
    if (t.floorDb > -199) o.card("Noise floor", fmt("%.1f dBFS", t.floorDb));
    if (t.peakDb > -199) o.card("Peak", fmt("%.1f dBFS at %+.1f kHz", t.peakDb, t.peakOffsetHz / 1e3));
    if (t.fftSize > 0 && t.rate > 0) o.card("Resolution", fmt("%.1f Hz", t.rate / t.fftSize));
    o.card("Averaging", std::to_string(t.averaging));
    if (t.fftSize > 0 && t.rate > 0 && (int)t.spectrum.size() == t.fftSize) peakTable(o, t.spectrum, t.floorDb, -t.rate / 2, t.rate / t.fftSize, false);
}

void spectrumAnalyser(Out& o, const SpecanTelemetry& t) {
    o.card("State", t.blocksOk ? "sweeps coming" : "waiting for the first sweep");
    o.card("Sweep", t.native ? "HackRF sweep" : "stepped");
    o.card("Sweeps ok / with gaps", pair(t.blocksOk, t.blocksBad));
    if (t.sweepMs > 0) o.card("Sweep time", fmt("%.0f ms", t.sweepMs));
    if (t.steps > 0) o.card("Steps", std::to_string(t.steps));
    if (t.binHz > 0) o.card("Resolution", fmt("%.1f kHz", t.binHz / 1e3));
    if (t.blocksOk) o.card("Peak", fmt("%.1f dBFS at %.3f MHz", t.levelDb, t.peakHz / 1e6));
    if (!t.live.empty() && t.binHz > 0) {
        std::vector<float> sorted(t.live);
        std::nth_element(sorted.begin(), sorted.begin() + (long)sorted.size() / 2, sorted.end());
        const float floorDb = sorted[sorted.size() / 2];
        o.card("Median level", fmt("%.1f dBFS", floorDb));
        peakTable(o, t.live, floorDb, t.loHz + t.binHz / 2, t.binHz, true);
    }
}

// ---- KA modes

void kaal(Out& o, const KaalTelemetry& t) {
    head(o, t.state >= 2 ? "locked" : t.state == 1 ? "searching" : "no input", t.snrDb, -200, t.cfoHz);
    o.card("Frames ok / bad", pair(t.blocksOk, t.blocksBad));
    o.card("Frame version", std::to_string(t.frameVersion));
    o.card("Symbol rate", fmt("%d ksym/s", t.symRate / 1000));
    if (t.bitrateKbps) o.card("Voice", fmt("%d kbit/s", t.bitrateKbps));
    if (t.beaconValid) {
        o.card("Station", t.callsign);
        if (!t.grid.empty()) o.card("Grid", t.grid);
        o.card("Beacon age", fmt("%.0f s", t.beaconAgeSec));
        if (!t.text.empty()) o.card("Text", t.text);
        if (t.lat != 0 || t.lon != 0) o.card("Position", fmt("%.4f, %.4f", t.lat, t.lon));
        o.card("Power", fmt("%.0f dBm", t.powerDbm));
    }
    if (t.sweepIdValid) o.card("Sweep ID", t.sweepId);
    if (t.frameVersion == 4) {
        o.card("Slots ok / bad", pair(t.v4SlotsOk, t.v4SlotsBad));
        Table s("Slots", {"Slot", "Talker", "Profile", "Playing"});
        for (int i = 0; i < 4; i++) s.row({std::to_string(i + 1), t.v4Call[i], std::to_string(t.v4Profile[i]), t.v4PlaySlot == i ? "yes" : ""});
        o.table(s);
    }
}

void kavb(Out& o, const KavbTelemetry& t) {
    static const char* const kind[] = {"video", "audio", "text", "picture", "data"};
    head(o, t.state >= 2 ? "locked" : t.state == 1 ? "searching" : "no input", t.esn0Db, -200, t.cfoHz);
    if (t.profile >= 0) o.card("Profile", std::string(1, (char)('A' + std::min(t.profile, 25))) + (t.robust ? " (robust)" : ""));
    o.card("Symbol rate", fmt("%.0f ksym/s", t.symRate / 1e3));
    o.card("Frames ok / bad", pair(t.framesGood, t.framesBad));
    o.card("Blocks ok / bad", pair(t.blocksOk, t.blocksBad));
    o.card("FEC groups ok / restored / lost", std::to_string(t.groupsOk) + " / " + std::to_string(t.groupsRecovered) + " / " + std::to_string(t.groupsLost));
    o.card("Throughput", fmt("%.1f kbit/s", t.throughputBps / 1e3));
    if (!t.callsign.empty()) o.card("Station", t.callsign);
    if (!t.saveError.empty()) o.card("Saving", t.saveError);
    Table p("Packets", {"Signal s", "Type", "Stream", "Seq", "Bytes"});
    for (const KavbPacketInfo* x : latest(t.recent, true))
        p.row({fmt("%.1f", x->atSec), x->type >= 0 && x->type < 5 ? kind[x->type] : "", std::to_string(x->stream), std::to_string(x->seq), std::to_string(x->bytes)});
    o.table(p);
}

void kait(Out& o, const KaitTelemetry& t) {
    static const char* const st[] = {"no input", "listening for a sweep", "receiving a burst", "decoding", "burst decoded"};
    head(o, st[std::clamp(t.state, 0, 4)], t.snrDb, -200, t.cfoHz);
    if (t.state == 2) o.card("Captured", fmt("%.1f of 10 s", t.captureSec));
    o.card("Bursts seen / decoded", pair(t.bursts, t.burstsDecoded));
    if (t.headerOk) {
        o.card("Station", t.callsign);
        o.card("Picture", fmt("%d x %d", t.width, t.height));
        o.card("Layers", fmt("%d of %d", t.layersComplete, t.nLayers));
        o.card("Bytes good", fmt("%zu of %zu", t.bytesGood, t.bytesTotal));
    }
    o.card("Blocks ok / bad", pair(t.blocksOk, t.blocksBad));
    Table l("Layers", {"Layer", "Blocks", "Blocks ok"});
    for (size_t i = 0; i < t.layerBlocks.size() && i < t.layerBlocksOk.size(); i++) l.row({std::to_string(i + 1), std::to_string(t.layerBlocks[i]), std::to_string(t.layerBlocksOk[i])});
    o.table(l);
}

void kapp(Out& o, const KappTelemetry& t) {
    head(o, t.state >= 2 ? "receiving" : t.state == 1 ? "listening" : "no input", t.snrDb, -200, t.cfoHz);
    if (!t.callsign.empty()) o.card("Station", t.callsign);
    if (t.profile >= 0) o.card("Profile", std::to_string(t.profile));
    o.card("Bursts", count(t.bursts));
    o.card("Blocks ok / bad", pair(t.blocksOk, t.blocksBad));
    o.card("Messages", count(t.messages));
    o.card("Repeats", count(t.repeats));
    o.card("Throughput", fmt("%.1f kbit/s", t.throughputBps / 1e3));
    if (t.partialMessages) o.card("Incomplete", fmt("%u messages, %u bytes", t.partialMessages, t.partialBytes));
    Table m("Messages", {"Time UTC", "From", "To", "Text", "Signal s", "Bytes", "Profile", "SNR dB"});
    for (const KappPacket* x : latest(t.packets, true))
        m.row({"", x->callsign, "", x->binary ? "(binary)" : x->preview, fmt("%.1f", x->atSec), std::to_string(x->bytes), std::to_string(x->profile), fmt("%.0f", x->snrDb)});
    o.table(m);
}

void kaft(Out& o, const KaftTelemetry& t) {
    static const char* const session[] = {"none", "announced", "receiving", "complete and verified", "failed"};
    static const char* const width[] = {"1 MHz", "500 kHz", "200 kHz"};
    head(o, t.state >= 2 ? "receiving" : t.state == 1 ? "searching" : "no input", t.esN0Db, -200, t.cfoHz);
    if (t.width >= 0 && t.width < 3) o.card("Width", width[t.width]);
    if (t.profile >= 0) o.card("Profile", std::to_string(t.profile));
    if (!t.callsign.empty()) o.card("Station", t.callsign);
    o.card("Blocks ok / bad", pair(t.blocksOk, t.blocksBad));
    o.card("Throughput", fmt("%.1f kbit/s", t.throughputBps / 1e3));
    o.card("Transfer", session[std::clamp(t.session, 0, 4)]);
    if (t.session >= 1) {
        if (!t.fileName.empty()) o.card("File", t.fileName);
        if (t.fileBytes) o.card("Received", fmt("%.0f %%", 100.0 * (double)t.haveBytes / (double)t.fileBytes));
    }
    Table f("Files", {"Signal s", "File", "Bytes", "Note"});
    for (const KaftFile* x : latest(t.files, true)) f.row({fmt("%.1f", x->atSec), x->name, count(x->bytes), x->note});
    o.table(f);
}

void kaws(Out& o, const KawsTelemetry& t) {
    head(o, t.state >= 2 ? "receiving" : t.state == 1 ? (t.syncLock ? "preamble found" : "listening") : "no input", t.snrDb > -99 ? t.snrDb : 0, -200, t.cfoHz);
    if (t.profile >= 0) o.card("Profile", fmt("P%d", t.profile));
    o.card("Blocks ok / bad", pair(t.blocksOk, t.blocksBad));
    o.card("Messages", count(t.messages));
    o.card("Beacons", count(t.beacons));
    o.card("Lattice hits", pair(t.latticeHits, t.slotsTried));
    if (!t.voiceNote.empty()) o.card("Voice", t.voiceNote);
    Table m("Messages", {"Time UTC", "From", "To", "Text", "Profile", "SNR dB"});
    for (const KawsChat* x : latest(t.chats, true)) m.row({hhmmss((int64_t)x->utc), x->from, x->to, x->text, fmt("P%d", x->profile), fmt("%.0f", x->snrDb)});
    o.table(m);
    Table b("Beacons", {"Time UTC", "Call", "Grid", "Text", "Position", "dBm", "SNR dB"});
    for (const KawsBeaconEntry* x : latest(t.beaconList, true))
        b.row({hhmmss((int64_t)x->utc), x->call, x->grid, x->text, x->full ? fmt("%.3f, %.3f", x->lat, x->lon) : "", x->full ? fmt("%.0f", x->powerDbm) : "", fmt("%.0f", x->snrDb)});
    o.table(b);
}

void multitone(Out& o, const MultitoneTelemetry& t) {
    o.card("Signal", t.signal ? "carrier up" : "quiet");
    o.card("SNR", fmt("%.0f dB", t.snrDb));
    o.card("Level", fmt("%.1f dBFS", t.levelDb));
    o.card("Transmissions", count(t.txTotal));
    o.card("Data bursts", count(t.burstTotal));
    o.card("Valid words", pair(t.blocksOk, t.blocksBad));
    Table x("Transmissions", {"Time UTC", "Kind", "Seconds", "SNR dB", "Deviation Hz", "Tones"});
    for (size_t i = 0; i < t.tx.size() && i < kMaxRows; i++) {
        const MtTx& v = t.tx[i];
        x.row({hhmmss(v.wall), v.kind, fmt("%.2f", v.durSec), fmt("%.0f", v.snrDb), fmt("%.0f", v.devHz), v.tones});
    }
    o.table(x);
    Table b("Data", {"Time UTC", "Baud", "Standard", "Bits", "Sync", "Valid words", "Verdict"});
    for (size_t i = 0; i < t.bursts.size() && i < kMaxRows; i++) {
        const MtBurst& v = t.bursts[i];
        b.row({hhmmss(v.wall), fmt("%.1f", v.baud), v.nearestStd, std::to_string(v.nBits), v.syncFound ? "yes" : "", fmt("%d / %d", v.validWords, v.totalWords), v.verdict});
    }
    o.table(b);
    Table n("Tones", {"Hz", "Heard", "Seconds"});
    for (const MtTone& v : t.tones) n.row({fmt("%.1f", v.hz), std::to_string(v.count), fmt("%.1f", v.totalSec)});
    o.table(n);
}

void horusBalloons(Out& o, const HorusTelemetry& t) {
    o.card("Balloons", count(t.payloads.size()));
    o.card("Packets ok / bad", pair(t.blocksOk, t.blocksBad));
    o.card("Syncs", count(t.syncs));
    o.card("SNR", fmt("%.0f dB", t.snrDb));
    o.card("Level", fmt("%.1f dBFS", t.levelDb));
    if (!t.payloads.empty()) {
        const HorusPayload& p = t.payloads.front();
        o.card("Altitude", fmt("%.0f m", p.last.altM));
        o.card("Highest", fmt("%.0f m", p.maxAltM));
        if (p.hasAscent) o.card("Climb", fmt("%+.1f m/s", p.ascentMs));
        if (p.last.battV > 0) o.card("Battery", fmt("%.2f V", p.last.battV));
        if (p.last.sats >= 0) o.card("Satellites", std::to_string(p.last.sats));
    }
    Table b("Balloons", {"Call", "Lat", "Lon", "Alt m", "Climb m/s", "Packets", "Age s"});
    for (const HorusPayload& p : t.payloads)
        b.row({p.callsign, fmt("%.5f", p.last.lat), fmt("%.5f", p.last.lon), fmt("%.0f", p.last.altM), p.hasAscent ? fmt("%+.1f", p.ascentMs) : "", count(p.packets), fmt("%.0f", p.lastHeardS)});
    o.table(b);
    Table k("Packets", {"Time UTC", "Call", "Seq", "Alt m", "Speed km/h", "Temp C", "SNR dB"});
    for (size_t i = 0; i < t.packets.size() && i < kMaxRows; i++) {
        const horus::Packet& p = t.packets[i];
        k.row({hhmmss(p.wallTime), p.callsign, std::to_string(p.seq), fmt("%.0f", p.altM), p.speedKmh >= 0 ? std::to_string(p.speedKmh) : "", p.tempC > -128 ? std::to_string(p.tempC) : "", fmt("%.0f", p.snrDb)});
    }
    o.table(k);
}

// ---- television

// ATSC 3.0: the details stay in Engine::atsc3Telemetry and only what every mode shares comes in RxTelemetry
void atsc3(Out& o, const RxTelemetry& rx) {
    o.card("State", rx.state >= 2 ? "locked" : rx.state == 1 ? "bootstraps heard" : "searching");
    if (rx.cfoHz != 0) o.card("CFO", fmt("%+.0f Hz", rx.cfoHz));
    o.card("Service data", rx.dataValid ? "ready" : "not yet");
    o.card("Baseband packets ok / bad", pair(rx.blocksOk, rx.blocksBad));
}

void isdbTerrestrial(Out& o, const RxTelemetry& rx) {
    const auto& t = rx.isdbt;
    o.card("State", rx.state >= 2 ? "locked" : rx.state == 1 ? "partly locked" : "searching");
    o.card("TMCC", t.tmccOk ? "ok" : "no");
    if (t.mode) o.card("Mode", std::to_string(t.mode));
    if (rx.giIdx >= 0) o.card("Guard interval", isdbt::guardName(rx.giIdx));
    o.card("Bandwidth", fmt("%d MHz", t.bwMhz));
    if (rx.dataSnrDb != 0) o.card("SNR", fmt("%.1f dB", rx.dataSnrDb));
    if (rx.cfoHz != 0) o.card("CFO", fmt("%+.0f Hz", rx.cfoHz));
    if (t.partial) o.card("Partial reception", "yes");
    if (t.emergency) o.card("Emergency alert", "on");
    Table l("Layers", {"Layer", "Segments", "Modulation", "Rate", "Sync", "Packets", "RS clean", "RS fixed", "RS failed"});
    for (int i = 0; i < 3; i++) {
        const auto& x = t.layer[i];
        if (!x.segments) continue;
        l.row({std::string(1, (char)('A' + i)), std::to_string(x.segments), isdbt::modName(x.mod), isdbt::rateName(x.rate), yesNo(x.synced), count(x.packets), count(x.rsClean), count(x.rsCorrected), count(x.rsFailed)});
    }
    o.table(l);
}

void isdbSatellite(Out& o, const IsdbsTelemetry& t) {
    static const char* const st[] = {"no input", "searching", "frame sync", "TMCC decoded", "transport stream"};
    head(o, st[std::clamp(t.state, 0, 4)], t.snrDb, -200, t.cfoHz);
    o.card("Frames", count(t.frames));
    o.card("TMCC ok / bad", pair(t.tmccGood, t.tmccBad));
    o.card("Reed-Solomon clean / fixed / failed", std::to_string(t.rsClean) + " / " + std::to_string(t.rsCorrected) + " / " + std::to_string(t.rsFailed));
    o.card("Packets", count(t.packets));
    if (t.selected >= 0) o.card("Stream", std::to_string(t.selected));
    if (t.tsBitrate > 0) o.card("Stream rate", fmt("%.2f Mbit/s", t.tsBitrate / 1e6));
    if (t.tmcc.valid && t.tmcc.ews) o.card("Emergency alert", "on");
    Table s("Streams", {"Stream", "TS id", "Slots", "Modulation", "Mbit/s", "Decoding"});
    for (const IsdbsStreamRow& x : t.streams)
        s.row({std::to_string(x.rel), fmt("%04X", x.tsId), std::to_string(x.slots), x.mixed ? "mixed" : isdbs::modName(x.mod), fmt("%.2f", x.bitrate / 1e6), x.rel == t.selected ? "yes" : ""});
    o.table(s);
}

void analogTvCards(Out& o, const AtvTelemetry& t) {
    if (!t.system.empty()) o.card("System", t.system);
    if (!t.colourSystem.empty()) o.card("Colour", t.colourSystem + (t.colour ? "" : t.colourKiller ? " (burst too weak)" : ""));
    o.card("Sync", fmt("%.0f %%", t.syncQuality * 100));
    if (t.fieldHz > 0) o.card("Field rate", fmt("%.2f Hz", t.fieldHz));
    o.card("Sound", t.soundPresent ? (t.soundSystem.empty() ? "yes" : t.soundSystem) : "none");
    if (t.carrierToNoiseDb != 0) o.card("Carrier to noise", fmt("%.1f dB", t.carrierToNoiseDb));
    o.card("Fields ok / bad", pair(t.blocksOk, t.blocksBad));
}

void analogTv(Out& o, const AtvTelemetry& t) {
    head(o, t.state >= 2 ? "locked" : t.state == 1 ? "carrier and line sync" : "searching", t.snrDb, t.carrierDbfs > -119 ? t.carrierDbfs : -200, t.cfoHz);
    analogTvCards(o, t);
}

void fpv(Out& o, const FpvTelemetry& t) {
    head(o, t.state >= 2 ? "video locked" : t.state == 1 ? "transmitter found" : "no transmitter", t.snrDb, t.levelDb, t.cfoHz);
    if (t.tunedHz > 0) o.card("Channel", (t.tunedName.empty() ? "" : t.tunedName + " ") + fmt("%.0f MHz", t.tunedHz / 1e6));
    o.card("Over noise", fmt("%.1f dB", t.overDb));
    if (t.state >= 2) analogTvCards(o, t.video);
    if (t.audioOn) o.card("Audio subcarrier", t.audioPresent ? fmt("%.1f MHz", t.audioSubHz / 1e6) : "none");
    Table c("Transmitters", {"Channel", "MHz", "Level dBFS", "Over noise dB", "In capture", "Age s"});
    for (const FpvChannelInfo& x : t.channels)
        if (x.present) c.row({x.name, fmt("%.0f", x.freqHz / 1e6), fmt("%.1f", x.levelDb), fmt("%.1f", x.overDb), yesNo(x.inCapture), x.ageSec >= 0 ? fmt("%.0f", x.ageSec) : ""});
    o.table(c);
}

void mac(Out& o, const MacTelemetry& t) {
    head(o, t.state >= 2 ? "frame sync" : t.state == 1 ? "line sync" : "searching", t.snrDb, t.levelDb, t.cfoHz);
    if (!t.variantName.empty()) o.card("System", t.variantName);
    if (!t.channelName.empty()) o.card("Service", t.channelName);
    if (!t.networkName.empty()) o.card("Network", t.networkName);
    if (!t.country.empty()) o.card("Country", t.country);
    if (t.satChannel >= 0) o.card("Satellite channel", std::to_string(t.satChannel));
    if (t.aspectKnown) o.card("Aspect", t.wide ? "16:9" : "4:3");
    o.card("Access", t.scrambling.empty() ? (t.scrambled ? "scrambled" : "clear") : t.scrambling);
    if (!t.caSystem.empty()) o.card("Conditional access", t.caSystem);
    o.card("Packets", count(t.packets));
    o.card("Bit error rate", fmt("%.1e", t.bitErrorRate));
    if (t.videoSnrDb != 0) o.card("Video SNR", fmt("%.1f dB", t.videoSnrDb));
    o.card("Sound", t.soundPresent ? (t.soundMode.empty() ? "yes" : t.soundMode) : t.soundScrambled ? "scrambled, not played" : "none");
}

void tvSatBeacon(Out& o, const SbTelemetry& t) {
    static const char* const st[] = {"no carrier", "carrier locked", "subcarrier and bit clock", "frames found"};
    static const char* const conf[] = {"raw", "estimated", "decoded"};
    head(o, st[std::clamp(t.state, 0, 3)], 0, t.levelDb, t.cfoHz);
    if (t.state) o.card("C/N0", fmt("%.1f dB-Hz", t.snrDb));
    if (t.driftHzPerMin != 0) o.card("Drift", fmt("%+.2f Hz/min", t.driftHzPerMin));
    if (t.subcarrierHz > 0) o.card("Subcarrier", fmt("%.1f kHz", t.subcarrierHz / 1e3));
    if (t.baud > 0) o.card("Bit rate", fmt("%.0f bit/s%s", t.baud, t.coding == 1 ? ", bi-phase" : ""));
    if (t.frameBits) o.card("Frame", fmt("%d bits", t.frameBits));
    if (!t.syncName.empty()) o.card("Sync word", t.syncName);
    o.card("Frames ok / bad", pair(t.blocksOk, t.blocksBad));
    Table i("Summary", {"Item", "Value", "Confidence", "How"});
    for (const SbInfo* x : latest(t.info, false)) i.row({x->label, x->value, conf[std::clamp(x->confidence, 0, 2)], x->how});
    o.table(i);
    Table f("Fields", {"Field", "Value", "Unit", "Bytes", "Confidence", "How"});
    for (const SbField* x : latest(t.fields, false))
        f.row({x->name, x->value, x->unit, x->firstByte == x->lastByte ? std::to_string(x->firstByte) : fmt("%d-%d", x->firstByte, x->lastByte), conf[std::clamp(x->confidence, 0, 2)], x->how});
    o.table(f);
    Table l("Carriers", {"Offset kHz", "Over noise dB", "From main dB", "Note"});
    for (const SbLine* x : latest(t.lines, true)) l.row({fmt("%+.2f", x->offsetHz / 1e3), fmt("%.1f", x->levelDb), fmt("%.1f", x->relDb), x->side ? "line of the modulation" : ""});
    o.table(l);
    Table r("Frames", {"Frame", "Counter", "Fixed bit errors", "Good"});
    for (const SbFrame* x : latest(t.frames, true)) r.row({std::to_string(x->id), x->counter >= 0 ? std::to_string(x->counter) : "", std::to_string(x->fixedErrors), yesNo(x->good)});
    o.table(r);
}

// ---- digital radio

void amStereo(Out& o, const CquamTelemetry& t) {
    head(o, t.state >= 2 ? "stereo" : t.state == 1 ? "carrier locked, mono" : "no carrier", t.snrDb, t.levelDb, t.cfoHz);
    o.card("25 Hz pilot", t.pilotSeen ? fmt("%.1f %%", t.pilotPct) : "none");
    o.card("Lock quality", fmt("%.2f", t.lockQuality));
    if (t.modPct > 0) o.card("Modulation", fmt("%.0f %%", t.modPct));
    if (t.leftDb > -199) o.card("Left / right", fmt("%.1f / %.1f dBFS", t.leftDb, t.rightDb));
    if (t.widthDb > -199) o.card("L-R over L+R", fmt("%.1f dB", t.widthDb));
    o.card("Bandwidth", fmt("%.0f Hz", t.widthHz));
}

void drm(Out& o, const DrmTelemetry& t) {
    head(o, t.state >= 2 ? "locked" : t.state == 1 ? "partly locked" : "searching", t.snrDb, t.levelDbfs > -119 ? t.levelDbfs : -200, t.cfoHz);
    if (t.mode >= 0) o.card("Mode", fmt("%c, %.1f kHz", t.modeName, t.bandwidthKhz));
    if (t.mscQam) o.card("MSC / SDC", fmt("%d-QAM / %d-QAM", t.mscQam, t.sdcQam));
    if (t.longInterleave >= 0) o.card("Interleave", t.longInterleave ? "long (2 s)" : "short (400 ms)");
    o.card("FAC ok / bad", pair(t.facOk, t.facBad));
    o.card("SDC ok / bad", pair(t.sdcOk, t.sdcBad));
    o.card("Audio frames ok / bad", pair(t.blocksOk, t.blocksBad));
    if (t.timeValid) o.card("Time", fmt("%04d-%02d-%02d %02d:%02d UTC", t.year, t.month, t.day, t.hour, t.minute));
    if (!t.audioInfo.empty()) o.card("Audio", t.audioInfo);
    if (!t.status.empty()) o.card("Status", t.status);
    Table s("Services", {"Service", "Type", "kbit/s", "Subch", "Now playing"});
    for (const DrmService& x : t.services) {
        const bool playing = x.audio && x.shortId == t.serviceAudioSelected;
        s.row({x.label.empty() ? fmt("Service %d", x.shortId + 1) : x.label, x.audio ? "audio" : "data", x.bitrateBps > 0 ? fmt("%.1f", x.bitrateBps / 1e3) : "", x.audio ? std::to_string(x.shortId) : "",
               playing ? t.textMessage : x.audio ? "" : x.appName});
    }
    o.table(s);
}

void hdRadio(Out& o, const HdrTelemetry& t) {
    static const char* const st[] = {"searching", "signal found", "locked", "decoding"};
    head(o, st[std::clamp(t.state, 0, 3)], t.snrDb, t.levelDb, t.cfoHz);
    if (!t.modeName.empty()) o.card("Service mode", std::string(t.band == 2 ? "AM " : "FM ") + t.modeName);
    if (!t.callSign.empty()) o.card("Station", t.callSign);
    const std::string name = !t.longName.empty() ? t.longName : t.stationName;
    if (!name.empty()) o.card("Name", name);
    if (!t.slogan.empty()) o.card("Slogan", t.slogan);
    if (!t.message.empty()) o.card("Message", t.message);
    if (!t.alert.empty()) o.card("Alert", t.alert);
    o.card("P1 frames ok / bad", pair(t.blocksOk, t.blocksBad));
    o.card("Sound", t.hdcPlaying ? "playing" : t.hdcFound ? "decoder ready" : t.hdcProblem.empty() ? "HDC decoder not installed (silent)" : t.hdcProblem);
    Table s("Services", {"Service", "Type", "kbit/s", "Subch", "Now playing"});
    for (const HdrProgram& x : t.programs) {
        const char* type = hdrProgramTypeName(x.type);
        const std::string now = x.artist.empty() ? x.title : x.title.empty() ? x.artist : x.artist + " - " + x.title;
        s.row({fmt("HD%d", x.number + 1) + (x.name.empty() ? "" : " " + x.name), type && *type ? type : "audio", x.kbps > 0 ? fmt("%.1f", x.kbps) : "", std::to_string(x.number), now});
    }
    o.table(s);
    Table d("Data services", {"Service", "Type", "Port", "Packets", "kB"});
    int n = 0;
    for (const HdrDataService& x : t.dataServices) {
        if (++n > (int)kMaxRows) break;
        const char* type = hdrDataTypeName(x.sdType);
        d.row({x.name, type ? type : "", x.port >= 0 ? std::to_string(x.port) : "", count(x.packets), fmt("%.1f", (double)x.bytes / 1e3)});
    }
    o.table(d);
    Table l("Files", {"Name", "Port", "Bytes", "Complete"});
    for (const HdrLotInfo* x : latest(t.lots, true)) l.row({x->name, std::to_string(x->port), x->size ? fmt("%u of %u", x->have, x->size) : std::to_string(x->have), x->complete ? "yes" : ""});
    o.table(l);
}

void cdr(Out& o, const CdrTelemetry& t) {
    head(o, cdrStateText(t.state), t.snrDb, t.levelDb, t.cfoHz);
    if (t.tm) o.card("Mode / spectrum", fmt("%d / %d", t.tm, t.sm));
    if (!t.network.empty()) o.card("Network", t.network);
    if (!t.country.empty()) o.card("Country", t.country);
    o.card("LDPC ok / bad", pair(t.blocksOk, t.blocksBad));
    o.card("System information ok / bad", pair(t.siOk, t.siBad));
    o.card("Multiplex frames ok / bad", pair(t.muxOk, t.muxBad));
    if (t.clipPct > 0) o.card("Clipping", fmt("%.1f %%", t.clipPct));
    o.card("Sound", t.draFound ? "DRA+ decoder ready" : t.draProblem.empty() ? "DRA+ add-on not installed (silent)" : t.draProblem);
    if (!t.status.empty()) o.card("Status", t.status);
    // Service names are in the electronic service guide, which is not decoded: the identifier is the name
    Table s("Services", {"Service", "Type", "kbit/s", "Subch", "Now playing"});
    for (const CdrServiceInfo& x : t.services)
        s.row({fmt("Service %u", x.id), x.audio && x.data ? "audio + data" : x.audio ? "audio" : x.data ? "data" : "", x.kbps > 0 ? fmt("%.1f", x.kbps) : "", x.audio ? std::to_string(x.id) : "", x.text});
    o.table(s);
    Table n("Not decoded", {"Note"});
    for (const std::string* x : latest(t.notes, false)) n.row({*x});
    o.table(n);
}
} // namespace

bool utilityTools(const dect2::RxTelemetry& rx, Out& o) {
    switch (rx.standard) {
    // television (0, 1, 2, 7, 8 and 41 are in results_json.cpp)
    case 4: atsc3(o, rx); return true;
    case 5: isdbTerrestrial(o, rx); return true;
    case 9: analogTv(o, rx.atv); return true;
    case 48: mac(o, rx.mac); return true;
    case 102: fpv(o, rx.fpv); return true;
    case 145: tvSatBeacon(o, rx.satbeacon); return true;
    case 155: isdbSatellite(o, rx.isdbs); return true;
    // radio
    case 11: drm(o, rx.drm); return true;
    case 22: hdRadio(o, rx.hdr); return true;
    case 23: cdr(o, rx.cdr); return true;
    case 108: amStereo(o, rx.cquam); return true;
    // two-way
    case 32: m17(o, rx.m17); return true;
    case 80: tetrapol(o, rx.tetrapol); return true;
    case 90: tones(o, rx.tones); return true;
    case 128: mpt1327(o, rx.mpt1327); return true;
    case 129: fusion(o, rx.fusion); return true;
    case 130: ltr(o, rx.ltr); return true;
    case 131: edacs(o, rx.edacs); return true;
    case 181: p25p2(o, rx.p25p2); return true;
    // HF data and utility
    case 50: ale(o, rx.ale); return true;
    case 68: hfBeacons(o, rx.hfb); return true;
    case 73: codar(o, rx.codar); return true;
    case 75: datawell(o, rx.datawell); return true;
    case 96: mt63(o, rx.mt63); return true;
    case 114: kbd33(o, rx.fsq); return true;
    case 117: kbd33(o, rx.ifkp); return true;
    case 120: sitor(o, rx.sitor); return true;
    case 141: ardop(o, rx.ardop); return true;
    case 146: milhf(o, rx.milhf); return true;
    case 204: pactor(o, rx.pactor); return true;
    case 206: roshf(o, rx.roshf); return true;
    case 213: shortwave(o, rx.shortwave); return true;
    case 238: case 239: case 240: pactorHf(o, rx.pactorhf); return true;
    // tools
    case 42: spectrumExplorer(o, rx.specx); return true;
    case 43: spectrumAnalyser(o, rx.specan); return true;
    case 74: workbench(o, rx.wb); return true;
    // KA modes
    case 123: kaal(o, rx.kaal); return true;
    case 124: kavb(o, rx.kavb); return true;
    case 125: kapp(o, rx.kapp); return true;
    case 126: kaft(o, rx.kaft); return true;
    case 132: kait(o, rx.kait); return true;
    case 134: kaws(o, rx.kaws); return true;
    case 76: multitone(o, rx.multitone); return true;
    case 157: horusBalloons(o, rx.horus); return true;
    default: return false;
    }
}

} // namespace onair::results
