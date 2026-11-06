// The iOS side of app/main.cpp: the C API of onair_host.h over appRunInit / appRunFrame, touch to ImGuiIO, the pages.
#include "onair_host.h"
#include "app.h"
#include "main_internal.h"
#include "imgui_internal.h"
#include "ui/touch.h"
#include "ui/settings_table.h"
#include "gfx/colormap.h"
#include "results_json.h"
#include "dect2/channels/freq_db.h"
#include "dect2/channels/tvplan.h"
#include "platform/platform.h"
#include "dect2/tv/teletext.h"
#include "dect2/tx/tx.h"
#include "dect2/tx/tx_iqfile.h"
#include "dect2/tv/player.h"
#include "dect2/tv/ts.h"
#include <chrono>
#include <thread>
#include "platform/power.h"
#include "dect2/common/thread_name.h"
#include "dect2/net/netradio.h"
#include "dect2/net/remote_api.h"
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#include <cfloat>
#include <set>
#include <string>
#include <vector>

extern "C" void onair_shim_geometry(int w, int h, int fbW, int fbH, float scale);   // glfw_shim.mm
namespace gfx { void setHostLayer(CAMetalLayer* layer); void setBackground(bool on); }  // gfx_metal.mm
namespace power { void setHostOccluded(bool on); }                                     // ios/platform/power_ios.mm
void routeTab(App& a, const std::string& name);                                     // ui/main_tabs.cpp

namespace dect2 { void audioIosRecent(float* stereo, int frames); uint64_t audioIosPlayedFrames(); }                   // audioout_ios.mm
bool settingsIsBound(const settings::Info& i);                                       // ui/settings_window.cpp
settings::Val settingsRead(App& a, const settings::Info& i);
void generalSetDemodWidth(int demod, double widthHz);
int generalCurrentDemod();
double generalCurrentWidth();
std::vector<dect2::FreqEntry> freqdbForCurrentMode(App& a);                           // freqdb/freqdb_ui.cpp
void settingsWrite(App& a, const settings::Info& i, const settings::Val& v);

namespace {
constexpr int kFamilyFm = 5;
OnAirPage gPage = ONAIR_PAGE_TOUCH_SHELL;
bool gBackground = false, gStarted = false;
std::string gStatus, gJson, gVideoStatus;
uint64_t gVideoFrames = 0;
dect2::TxSession gTx;

// which TV plans fit the mode on screen, and the settings key of the one chosen (the keys of app/bandplan/tvchan_ui.cpp)
unsigned tvPlanMask(int family, const char** group) {
    switch (family) {
    case 0: *group = "dvb"; return dect2::tvplan::DvbAny;
    case 1: case 3: *group = "atsc"; return dect2::tvplan::Atsc | dect2::tvplan::Atsc3;
    case 4: *group = "isdbt"; return dect2::tvplan::IsdbT;
    case 7: *group = "dtmb"; return dect2::tvplan::Dtmb;
    case 8: *group = "analog"; return dect2::tvplan::Analog;
    case 40: *group = "dvbc"; return dect2::tvplan::DvbC;
    default: *group = ""; return 0;
    }
}

std::string phoneCountry() {
    NSString* code = [NSLocale.currentLocale countryCode];
    return code ? code.UTF8String : "";
}

std::string quoted(const std::string& s) { return "\"" + dect2::jsonEscape(s) + "\""; }
std::string textOf(double v) { return dect2::jsonNum(v); }

// The settings that do something in this app. An allow-list: most of the table is about desktop windows, themes, updates and programs that do not exist here
bool settingHidden(const settings::Info& i) {
    static const std::set<std::string> shown = {"wfMap3", "bwAuto", "subsOn", "fmMono", "fmStereo", "fmDeemph", "fmRegion", "fmSquelch", "adsbLat", "adsbLon"};
    return !shown.count(i.key);
}

const settings::Info* settingByKey(const char* key) {
    for (const settings::Info& i : settings::table()) if (!strcmp(i.key, key)) return &i;
    return nullptr;
}

void retuneIfRunning(App& a) { if (a.engine.running()) a.engine.retune(a.tune); }

// ---- fingers: the first one is ImGui's mouse; a second one cancels its press, so a pinch never tunes or drags
struct Finger { int id; float x, y; };
std::vector<Finger> gFingers;
bool gPressed = false, gPinch = false;

void cancelPress(float x, float y) {   // the release lands off the widget, so it is no click (as long press in touch.cpp:115)
    ImGuiIO& io = ImGui::GetIO();
    io.AddMousePosEvent(-FLT_MAX, -FLT_MAX);
    io.AddMouseButtonEvent(0, false);
    io.AddMousePosEvent(x, y);          // the plot under the fingers stays hovered: plot.cpp:290 needs that for the pinch
    gPressed = false;
}

void feedFingers() {   // touch::feedPointer wants every finger, every frame, before touch::frame() (touch.cpp:101)
    for (const Finger& f : gFingers) touch::feedPointer(f.id, f.x, f.y, true);
}

// The pages drawn in the body of the touch shell; the SwiftUI bar replaces its top bar and dock. All of them draw into the current window.
void pageBody(App& a, ImVec2) {
    switch (gPage) {
    case ONAIR_PAGE_RECEIVER: overviewTab(a); break;
    case ONAIR_PAGE_TUNER:
        toolbarParts(a, TbTuner | TbDecoder, true);
        if (sourceOptionsOpen(a)) sourceOptions(a);
        if (a.devices[a.devIdx].isRadio()) radioSettingsUi(a, true);
        break;
    case ONAIR_PAGE_GAIN: toolbarParts(a, TbGain, true); break;
    case ONAIR_PAGE_NONE: break;
    case ONAIR_PAGE_LIST: rightPanel(a); break;
    case ONAIR_PAGE_ANALYSIS: constellationsTab(a); break;
    default: mainTabs(a); break;   // MODE, and SETTINGS under its window
    }
}
}   // namespace

extern "C" {

bool onair_start(void* layer, const char*) {
    gfx::setHostLayer((__bridge CAMetalLayer*)layer);
    static char name[] = "OnAir";
    static char* argv[] = {name, nullptr};
    if (!appRunInit(1, argv)) return false;
    ImGuiPlatformIO& pio = ImGui::GetPlatformIO();
    pio.Platform_SetClipboardTextFn = [](ImGuiContext*, const char* text) { UIPasteboard.generalPasteboard.string = @(text); };
    pio.Platform_GetClipboardTextFn = [](ImGuiContext*) -> const char* {
        static std::string held;
        NSString* s = UIPasteboard.generalPasteboard.string;
        held = s ? s.UTF8String : "";
        return held.c_str();
    };
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"onair.ios.startMode"]) {   // the first launch starts on FM, then the user's choice is kept
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"onair.ios.startMode"];
        selectMode(appRunApp(), kFamilyFm);
    }
    gStarted = true;
    appRunApp().touchUi = true;   // main_window.cpp:113 leaves the work area unknown on Apple systems, so autoTouch() never fires
    return true;
}

bool onair_is_started(void) { return gStarted; }

void onair_frame(void) {
    feedFingers();
    appRunFrame();
}

void onair_flush(void) { appRunFlush(); }

void onair_set_background(bool background) {
    gBackground = background;
    ::power::setHostOccluded(background);   // the frame then ends in skipFrame() (main.cpp:429), the receivers keep ticking at 10 Hz
    gfx::setBackground(background);
    dect2::power::setAppHidden(false);      // the policy of the engine must not slow a receiver the user wants to hear
    if (background) onair_flush();
}

double onair_wanted_interval(void) { return appRunInterval(); }

void onair_resize(int w, int h, float scale) { onair_shim_geometry(w, h, (int)(w * scale), (int)(h * scale), scale); }

void onair_set_page(OnAirPage page) {
    gPage = page;
    const bool hidden = page == ONAIR_PAGE_NONE;   // the receiver logic still runs each frame, with no GPU work: nothing would ever be shown
    ::power::setHostOccluded(hidden);
    gfx::setBackground(hidden);
    settingsOpen() = page == ONAIR_PAGE_SETTINGS;   // a titled window: touch.cpp:60 makes it fill a narrow display
    touch::setShellHost(page == ONAIR_PAGE_TOUCH_SHELL ? nullptr : pageBody);
}

void onair_open_tab(const char* name) { routeTab(appRunApp(), name); }
int onair_tab_count(void) { return touch::tabCount(); }
const char* onair_tab_name(int i, bool* open) { return touch::tabName(i, open); }

void onair_touch(int id, float x, float y, int phase) {
    ImGuiIO& io = ImGui::GetIO();
    io.AddMouseSourceEvent(ImGuiMouseSource_TouchScreen);
    size_t k = 0;
    while (k < gFingers.size() && gFingers[k].id != id) k++;
    if (phase == 0 && k == gFingers.size()) gFingers.push_back({id, x, y});
    else if (k < gFingers.size() && phase == 1) { gFingers[k].x = x; gFingers[k].y = y; }
    if (gFingers.size() >= 2) {
        const float cx = (gFingers[0].x + gFingers[1].x) * 0.5f, cy = (gFingers[0].y + gFingers[1].y) * 0.5f;
        if (gPressed) cancelPress(cx, cy); else io.AddMousePosEvent(cx, cy);
        gPinch = true;
    } else if (!gPinch && !gFingers.empty()) {
        io.AddMousePosEvent(gFingers[0].x, gFingers[0].y);
        if (phase == 0 && gFingers.size() == 1) { io.AddMouseButtonEvent(0, true); gPressed = true; }
    }
    if (phase >= 2) {
        if (k < gFingers.size()) gFingers.erase(gFingers.begin() + (long)k);
        if (gFingers.empty()) {
            if (gPressed) {
                if (phase == 3) cancelPress(x, y); else io.AddMouseButtonEvent(0, false);
                gPressed = false;
            }
            gPinch = false;
            io.AddMousePosEvent(-FLT_MAX, -FLT_MAX);   // nothing stays hovered once the finger has gone
        }
    }
}

void onair_net_connect(int type, const char* host, int port) {
    App& a = appRunApp();
    if (a.netAddProbe) return;
    if (a.engine.running()) a.engine.stop();
    a.netAddType = type;
    snprintf(a.netAddHost, sizeof a.netAddHost, "%s", host);
    a.netAddPort = port;
    a.netAddErr.clear();
    auto pr = std::make_shared<App::NetProbe>();
    pr->radio.type = (dect2::NetRadio::Type)type;
    pr->radio.host = host;
    pr->radio.port = port;
    a.netAddProbe = pr;
    dect2::namedThread("onair-rigprobe", [pr] { std::string e; pr->ok = dect2::probeNetRadio(pr->radio, 3000, e); pr->err = e; pr->done = true; }).detach();
}

bool onair_net_busy(void) { return appRunApp().netAddProbe != nullptr; }
const char* onair_net_error(void) { return appRunApp().netAddErr.c_str(); }

void onair_text(const char* utf8) { ImGui::GetIO().AddInputCharactersUTF8(utf8); }

static void tapKey(ImGuiKey k) { ImGuiIO& io = ImGui::GetIO(); io.AddKeyEvent(k, true); io.AddKeyEvent(k, false); }
void onair_key_backspace(void) { tapKey(ImGuiKey_Backspace); }
void onair_key_enter(void) { tapKey(ImGuiKey_Enter); }
bool onair_wants_keyboard(void) { return ImGui::GetIO().WantTextInput; }
int onair_keyboard_kind(void) {
    ImGuiInputTextState* st = ImGui::GetInputTextState(ImGui::GetActiveID());
    return st && (st->Flags & ImGuiInputTextFlags_CharsDecimal) ? 1 : 0;
}

void onair_start_stop(void) {
    App& a = appRunApp();
    if (a.engine.running()) a.engine.stop(); else startReceiver(a);
}

void onair_tune_mhz(double mhz) { tuneFreq(appRunApp(), mhz); }

void onair_set_volume(float volume, bool muted) {
    App& a = appRunApp();
    a.volume = volume;
    a.muted = muted;
}

int onair_device_count(void) { return (int)appRunApp().devices.size(); }
const char* onair_device_name(int i) { return appRunApp().devices[(size_t)i].name.c_str(); }
int onair_device_selected(void) { return appRunApp().devIdx; }
void onair_device_select(int i) {
    App& a = appRunApp();
    if (i == a.devIdx || i < 0 || i >= (int)a.devices.size()) return;
    const bool wasRunning = a.engine.running();
    if (wasRunning) a.engine.stop();
    a.devIdx = i;
    savePrefs(a);
    if (wasRunning) startReceiver(a);
}

int onair_mode_count(void) { return kNumModes; }
const char* onair_mode_name(int i) { const ModeDef& m = kModes[i]; return m.sub && *m.sub ? m.sub : m.name; }
const char* onair_mode_group(int i) { const int g = kModes[i].group; return g >= 0 && g < kNumGroups ? kGroupNames[g] : ""; }
const char* onair_mode_blurb(int i) { return kModes[i].blurb ? kModes[i].blurb : ""; }
bool onair_mode_is_selected(int i) { return modeSelected(appRunApp(), kModes[i]); }
void onair_mode_select(int i) { selectMode(appRunApp(), kModes[i].family, kModes[i].subId); }

bool onair_spectrum(float* bins, int n, double* meta) {
    App& a = appRunApp();
    static uint64_t seq = 0;
    dect2::SpectrumFrame f;
    if (n <= 0 || !a.engine.latestSpectrum(f, seq) || f.dbfs.empty()) return false;
    seq = f.seq;
    const size_t N = f.dbfs.size();
    for (int i = 0; i < n; i++) {
        const size_t lo = (size_t)i * N / (size_t)n, hi = std::max(lo + 1, (size_t)(i + 1) * N / (size_t)n);
        float top = f.dbfs[lo];
        for (size_t k = lo + 1; k < hi && k < N; k++) top = std::max(top, f.dbfs[k]);
        bins[i] = top;
    }
    meta[0] = a.engine.captureCentreHz();
    meta[1] = a.engine.sampleRate();
    meta[2] = a.yMin;
    meta[3] = a.yMax;
    meta[4] = a.wf.minDb;
    meta[5] = a.wf.maxDb;
    return true;
}

void onair_colormap(unsigned* rgba, int n) {
    const int map = appRunApp().wf.effMap();
    for (int i = 0; i < n; i++) rgba[i] = cmap::color(map, n > 1 ? (float)i / (float)(n - 1) : 0.f);
}

void onair_spectrum_tune(double mhz) { spectrumTune(appRunApp(), mhz); }

void onair_spectrum_scrub(double mhz) {
    App& a = appRunApp();
    const double halfSpanMhz = a.engine.sampleRate() / 2e6 * 0.9;
    if (a.engine.running() && std::fabs(mhz - a.engine.captureCentreHz() / 1e6) < halfSpanMhz) tuneDecode(a, mhz);
    else tuneFreq(a, mhz);
}

bool onair_video_latest(OnAirVideoFrame* out) {
    App& a = appRunApp();
    static uint64_t seq = 0;
    static std::shared_ptr<const dect2::VideoFrame> held;
    std::shared_ptr<const dect2::VideoFrame> f = a.engine.player().videoFrame(seq);
    if (!f) return false;
    held = f;
    gVideoFrames++;
    out->width = f->w;
    out->height = f->h;
    out->displayAspect = f->dar;
    out->y = f->y.empty() ? nullptr : f->y.data();
    out->uv = f->uv.empty() ? nullptr : f->uv.data();
    out->rgba = f->rgba.empty() ? nullptr : f->rgba.data();
    out->bt709 = f->bt709;
    out->fullRange = f->fullRange;
    return true;
}

const char* onair_tv_json(void) {
    App& a = appRunApp();
    dect2::PlayerStats st = a.engine.player().stats();
    std::string s = "{\"selected\":" + std::to_string(a.engine.player().selected()) + ",\"network\":" + quoted(a.ts.networkName) + ",\"muxKbps\":" + textOf(a.ts.muxKbps) +
                    ",\"status\":" + quoted(st.status) + ",\"video\":" + quoted(st.videoCodec) + ",\"audio\":" + quoted(st.audioCodec) + ",\"width\":" + std::to_string(st.width) +
                    ",\"height\":" + std::to_string(st.height) + ",\"fps\":" + textOf(st.fps) + ",\"hardware\":" + (st.hardware ? "true" : "false") + ",\"services\":[";
    bool first = true;
    for (const dect2::TsService& v : a.ts.services) {
        if (!first) s += ",";
        first = false;
        s += "{\"id\":" + std::to_string(v.id) + ",\"name\":" + quoted(v.name) + ",\"provider\":" + quoted(v.provider) + ",\"lcn\":" + std::to_string(v.lcn) + ",\"type\":" + quoted(v.typeName()) +
             ",\"now\":" + quoted(v.now) + ",\"next\":" + quoted(v.next) + ",\"scrambled\":" + (v.scrambled ? "true" : "false") + "}";
    }
    gJson = s + "]}";
    return gJson.c_str();
}

void onair_tv_play(int serviceId) {
    App& a = appRunApp();
    if (serviceId < 0) { a.engine.player().select(-1); a.playReq = -1; return; }
    a.playReq = serviceId;   // draw_ui.cpp starts it once its programme table has arrived, with the volume and language set
}

void onair_tv_play_file(const char* path) {
    App& a = appRunApp();
    a.engine.setPlayerExternal(true);
    std::string file = path;
    dect2::namedThread("onair-tsfile", [&a, file] {
        FILE* f = fopen(file.c_str(), "rb");
        if (!f) return;
        constexpr size_t kPackets = 512;
        std::vector<uint8_t> chunk(kPackets * 188);
        dect2::TsDemux demux;
        int sid = -1;
        fseek(f, 0, SEEK_END);
        const double bytesPerSecond = (double)ftell(f) / 60.0;   // the test files last a minute
        fseek(f, 0, SEEK_SET);
        for (;;) {
            const size_t n = fread(chunk.data(), 188, kPackets, f);
            if (n == 0) { fseek(f, 0, SEEK_SET); demux = dect2::TsDemux(); continue; }
            for (size_t i = 0; i < n; i++) demux.feed(chunk.data() + i * 188);
            const double seconds = (double)(n * 188) / bytesPerSecond;
            demux.advance(seconds);
            dect2::TsSnapshot snap = demux.snapshot();
            if (sid < 0) for (const dect2::TsService& v : snap.services) if (v.havePmt) { sid = v.id; a.engine.player().select(sid); a.engine.player().setVolume(a.volume); }
            a.engine.player().push(chunk.data(), n, snap);
            std::this_thread::sleep_for(std::chrono::duration<double>(seconds));
        }
    }).detach();
}

int onair_tv_first_service(void) {
    App& a = appRunApp();
    if (a.engine.player().selected() >= 0 || a.playReq >= 0) return -1;
    for (const dect2::TsService& v : a.ts.services) if (!v.scrambled && v.havePmt) return v.id;
    return -1;
}

void onair_tv_bandwidth(double mhz) {
    App& a = appRunApp();
    if (mhz <= 0) { setDvbBandwidth(a, -1); return; }
    for (int i = 0; i < (int)(sizeof kBw / sizeof *kBw); i++)
        if (std::fabs(kBw[i].mhz - mhz) < 0.1) { setDvbBandwidth(a, i); return; }
}

const char* onair_epg_json(int serviceId) {
    App& a = appRunApp();
    std::string s = "[";
    const auto it = a.epg.find(serviceId);
    if (it != a.epg.end())
        for (const dect2::EpgEvent& e : it->second) {
            if (s.size() > 1) s += ",";
            s += "{\"start\":" + std::to_string(e.start) + ",\"duration\":" + std::to_string(e.duration) + ",\"title\":" + quoted(e.title) + ",\"text\":" + quoted(e.text) +
                 ",\"extended\":" + quoted(e.extended) + ",\"genre\":" + std::to_string(e.genre) + "}";
        }
    gJson = s + "]";
    return gJson.c_str();
}

bool onair_teletext_page(int page, unsigned* cells, int* links) {
    dect2::TtxPage p;
    if (!appRunApp().engine.teletext().page(page, p)) return false;
    dect2::TtxGrid grid;
    dect2::ttxRender(p, grid);
    for (int r = 0; r < 25; r++)
        for (int c = 0; c < 40; c++) {
            const dect2::TtxCell& k = grid[(size_t)r][(size_t)c];
            const unsigned body = k.mosaic ? k.sextants : (k.ch & 0x1FFFFF);
            cells[r * 40 + c] = body | (unsigned)(k.fg & 7) << 21 | (unsigned)(k.bg & 7) << 24 | (k.mosaic ? 1u << 27 : 0u) | (unsigned)(k.dh & 3) << 28 | (k.separated ? 1u << 30 : 0u);
        }
    for (int i = 0; i < 4; i++) links[i] = p.fastext[i];
    return true;
}

const char* onair_teletext_pages_json(void) {
    std::string s = "[";
    for (int n : appRunApp().engine.teletext().pages()) { if (s.size() > 1) s += ","; s += std::to_string(n); }
    gJson = s + "]";
    return gJson.c_str();
}

void onair_audio_recent(float* stereo, int frames) { dect2::audioIosRecent(stereo, frames); }

int onair_fm_multiplex(float* db, int maxPoints, float* maxHz) {
    const auto& f = appRunApp().rx.fm;
    const int n = std::min(maxPoints, (int)f.mpxDb.size());
    for (int i = 0; i < n; i++) db[i] = f.mpxDb[(size_t)i];
    *maxHz = f.mpxMaxHz;
    return n;
}

int onair_fm_rds_symbols(float* xy, int maxPoints) {
    const auto& f = appRunApp().rx.fm;
    const int n = std::min(maxPoints, (int)f.rdsConst.size());
    for (int i = 0; i < n; i++) {
        xy[i * 2] = f.rdsConst[(size_t)i].real();
        xy[i * 2 + 1] = f.rdsConst[(size_t)i].imag();
    }
    return n;
}

const char* onair_fm_json(void) {
    const auto& f = appRunApp().rx.fm;
    gJson = "{\"state\":" + std::to_string(f.state) + ",\"station\":" + quoted(f.psName) + ",\"text\":" + quoted(f.radioText) + ",\"programme\":" + quoted(f.ptyText) +
            ",\"stereo\":" + (f.stereo ? "true" : "false") + ",\"snrDb\":" + textOf(f.snrDb) + ",\"levelDbfs\":" + textOf(f.levelDbfs) + ",\"rds\":" + (f.rdsSync ? "true" : "false") +
            ",\"rdsOk\":" + textOf(f.rdsBlockOkPct) + ",\"traffic\":" + (f.trafficProgram ? "true" : "false") + ",\"devKhz\":" + textOf(f.devKhz) + ",\"multipath\":" + textOf(f.multipathPct) + ",\"pilot\":" + textOf(f.pilotPct) + "}";
    return gJson.c_str();
}

const char* onair_channels_json(void) {
    App& a = appRunApp();
    namespace tp = dect2::tvplan;
    const char* group = "";
    const unsigned mask = tvPlanMask(a.family, &group);
    const tp::Plan* plan = nullptr;
    std::string out = "{";
    if (mask) {
        const std::string chosen = plat::prefs().getS((std::string("tvPlan.") + group).c_str(), "");
        if (!chosen.empty()) if (const tp::Plan* p = tp::find(chosen)) if (p->stds & mask) plan = p;
        if (!plan) plan = tp::defaultPlan(phoneCountry(), mask);
    }
    out += "\"plan\":" + quoted(plan ? plan->id : "") + ",\"planName\":" + quoted(plan ? plan->name : "") + ",\"plans\":[";
    if (mask) {
        bool first = true;
        for (const tp::Plan* p : tp::plansFor(mask)) { out += (first ? "" : ",") + ("{\"id\":" + quoted(p->id) + ",\"name\":" + quoted(p->name) + "}"); first = false; }
    }
    out += "],\"channels\":[";
    if (plan) {
        bool first = true;
        for (const tp::Channel& c : plan->channels) {
            if (c.legacy) continue;
            out += (first ? "" : ",") + ("{\"label\":" + quoted(c.label) + ",\"mhz\":" + textOf(c.centreHz / 1e6) + ",\"bandwidth\":" + textOf(c.bwHz / 1e6) + "}");
            first = false;
        }
    }
    out += "],\"known\":[";
    bool first = true;
    for (const dect2::FreqEntry& e : freqdbForCurrentMode(a)) {
        out += (first ? "" : ",") + ("{\"mhz\":" + textOf((double)e.hz / 1e6) + ",\"name\":" + quoted(e.name) + ",\"notes\":" + quoted(e.notes) + ",\"region\":" + quoted(e.region) + "}");
        first = false;
    }
    gJson = out + "]}";
    return gJson.c_str();
}

void onair_channel_plan_set(const char* planId) {
    App& a = appRunApp();
    const char* group = "";
    if (tvPlanMask(a.family, &group)) plat::prefs().setS((std::string("tvPlan.") + group).c_str(), planId);
}

void onair_channel_pick(double mhz, double bandwidthMhz) {
    App& a = appRunApp();
    if (bandwidthMhz > 0 && (a.family == 0 || a.family == 40)) onair_tv_bandwidth(bandwidthMhz);
    tuneFreq(a, mhz);
}

const char* onair_general_json(void) {
    App& a = appRunApp();
    const auto& g = a.rx.general;
    gJson = "{\"demod\":" + std::to_string(generalCurrentDemod()) + ",\"width\":" + textOf(generalCurrentWidth()) + ",\"levelDb\":" + textOf(g.levelDb) + ",\"noiseDb\":" + textOf(g.noiseDb) +
            ",\"snrDb\":" + textOf(g.snrDb) + ",\"squelchOpen\":" + (g.squelchOpen ? "true" : "false") + "}";
    return gJson.c_str();
}

void onair_general_set(int demod, double widthHz) { generalSetDemodWidth(demod, widthHz); }

bool onair_tx_supported(void) {
    App& a = appRunApp();
    const ModeDef* cur = nullptr;
    for (const auto& m : allModes()) if (modeSelected(a, m)) cur = &m;
    return cur && dect2::txModeForList(cur->family, cur->subId) != nullptr;
}

bool onair_tx_start(const OnAirTxRequest* q, char* err, int errSize) {
    App& a = appRunApp();
    auto fail = [&](const std::string& why) { snprintf(err, (size_t)errSize, "%s", why.c_str()); return false; };
    const ModeDef* cur = nullptr;
    for (const auto& m : allModes()) if (modeSelected(a, m)) cur = &m;
    const dect2::TxModeSpec* spec = cur ? dect2::txModeForList(cur->family, cur->subId) : nullptr;
    if (!spec) return fail("This mode has no transmitter");
    dect2::TxRequest r;
    r.modeId = spec->id;
    r.tune.centerHz = q->mhz * 1e6;
    r.tune.gainDb = q->gainDb;
    r.loop = q->seconds <= 0;
    r.onceSeconds = q->seconds;
    r.callsign = q->callsign ? q->callsign : "";
    r.grid = q->grid ? q->grid : "";
    r.text = q->text ? q->text : "";
    r.dest = q->dest ? q->dest : "";
    r.kind = q->kind;
    r.wpm = q->wpm > 0 ? q->wpm : 20;
    std::unique_ptr<dect2::TxSink> sink;
    dect2::TxRateLimits limits;
    if (q->iqPath && *q->iqPath) {
        dect2::IqFileTxConfig c;
        c.path = q->iqPath;
        c.centerHz = r.tune.centerHz;
        c.paced = false;
        c.description = spec->id;
        sink = std::make_unique<dect2::IqFileTxSink>(c);
    } else {
        const DeviceInfo& d = a.devices[(size_t)a.devIdx];
        if (!d.canTransmit) return fail("This radio cannot transmit");
        sink = dect2::makeTxSink(d);
        if (!sink) return fail("This radio cannot transmit");
        limits = dect2::TxRateLimits{d.txMinRateHz, d.txMaxRateHz};
    }
    std::string why;
    gTx.stop();
    if (!gTx.start(std::move(sink), r, limits, why)) return fail(why.empty() ? "The transmission could not start" : why);
    return true;
}

void onair_tx_stop(void) { gTx.stop(); }

const char* onair_tx_json(void) {
    const dect2::TxSession::Stats st = gTx.stats();
    gJson = std::string("{\"running\":") + (gTx.running() ? "true" : "false") + ",\"seconds\":" + textOf(st.seconds) + ",\"samples\":" + std::to_string(st.samples) +
            ",\"peak\":" + textOf(st.peak) + ",\"failed\":" + (st.failed ? "true" : "false") + ",\"error\":" + quoted(st.error) + "}";
    return gJson.c_str();
}

const char* onair_results_json(void) {
    App& a = appRunApp();
    gJson = onair::resultsJson(a.rx, a.engine.running());
    return gJson.c_str();
}

const char* onair_settings_json(void) {
    App& a = appRunApp();
    std::string out = "[";
    for (const settings::Info& i : settings::table()) {
        if (settingHidden(i) || !settingsIsBound(i)) continue;
        const settings::Val v = settingsRead(a, i);
        const char* kind = i.kind == settings::Kind::Bool ? "bool" : i.kind == settings::Kind::Choice ? "choice" : i.kind == settings::Kind::Int ? "int" :
                           i.kind == settings::Kind::Float ? "float" : "text";
        std::string names = "[";
        if (i.kind == settings::Kind::Choice) {
            bool first = true;
            for (const std::string& c : settings::split(i.choices ? i.choices : "", '|')) { names += (first ? "" : ",") + quoted(tr(c.c_str())); first = false; }
        }
        names += "]";
        const double shown = i.kind == settings::Kind::Choice ? (double)settings::choiceIndex(i, v.d) : v.d;
        if (out.size() > 1) out += ",";
        out += "{\"key\":" + quoted(i.key) + ",\"category\":" + quoted(tr(i.cat)) + ",\"label\":" + quoted(tr(i.label)) + ",\"help\":" + quoted(tr(i.tip)) +
               ",\"kind\":\"" + kind + "\",\"value\":" + textOf(shown) + ",\"text\":" + quoted(v.s) + ",\"lo\":" + textOf(i.lo) + ",\"hi\":" + textOf(i.hi) +
               ",\"choices\":" + names + "}";
    }
    gJson = out + "]";
    return gJson.c_str();
}

void onair_setting_set(const char* key, double value) {
    const settings::Info* i = settingByKey(key);
    if (!i) return;
    settings::Val v;
    v.d = i->kind == settings::Kind::Choice ? settings::choiceValue(*i, (int)value) : value;
    settingsWrite(appRunApp(), *i, v);
}

void onair_setting_set_text(const char* key, const char* value) {
    const settings::Info* i = settingByKey(key);
    if (!i) return;
    settings::Val v;
    v.s = value;
    settingsWrite(appRunApp(), *i, v);
}

const char* onair_gain_json(void) {
    App& a = appRunApp();
    const DeviceInfo& d = a.devices[(size_t)a.devIdx];
    const int dc = a.engine.autoOffset() ? 2 : a.engine.iqFix().dc ? 1 : 0;
    gJson = std::string("{\"radio\":") + (d.isRadio() ? "true" : "false") + ",\"generic\":" + (d.isGeneric() ? "true" : "false") + ",\"lo\":" + textOf(d.gainMinDb) +
            ",\"hi\":" + textOf(std::max(d.gainMaxDb, d.gainMinDb + 1.0)) + ",\"db\":" + textOf(a.tune.gainDb) + ",\"agc\":" + (a.agcOn ? "true" : "false") +
            ",\"iq\":" + (a.engine.iqFix().iq ? "true" : "false") + ",\"dc\":" + std::to_string(dc) + "}";
    return gJson.c_str();
}

void onair_gain_set(double db) {
    App& a = appRunApp();
    a.tune.gainDb = std::round(db);
    a.agcOn = false;
    retuneIfRunning(a);
}

void onair_agc_set(bool on) { appRunApp().agcOn = on; }

void onair_iq_fix_set(bool iq) {
    App& a = appRunApp();
    a.engine.iqFix().iq = iq;
    savePrefs(a);
}

void onair_dc_mode_set(int mode) {
    App& a = appRunApp();
    const bool wasOffset = a.engine.autoOffset();
    a.engine.iqFix().dc = mode == 1;
    a.engine.setAutoOffset(mode == 2);
    savePrefs(a);
    if (wasOffset != (mode == 2) && a.engine.running()) startReceiver(a);   // offset tuning is set up when the radio opens
}

const char* onair_radio_settings_json(void) {
    App& a = appRunApp();
    const DeviceInfo& d = a.devices[(size_t)a.devIdx];
    std::string out = "[";
    for (const dect2::RadioSetting& r : d.settings) {
        const char* kind = r.type == dect2::RadioSetting::Bool ? "bool" : r.type == dect2::RadioSetting::Choice ? "choice" : "number";
        const auto now = a.tune.radio.find(r.key);
        std::string values = "[", names = "[";
        for (size_t k = 0; k < r.values.size(); k++) {
            values += (k ? "," : "") + quoted(r.values[k]);
            names += (k ? "," : "") + quoted(k < r.names.size() ? r.names[k] : r.values[k]);
        }
        if (out.size() > 1) out += ",";
        out += "{\"key\":" + quoted(r.key) + ",\"label\":" + quoted(tr(r.label.c_str())) + ",\"help\":" + quoted(tr(r.help.c_str())) + ",\"kind\":\"" + kind +
               "\",\"value\":" + quoted(now != a.tune.radio.end() ? now->second : r.def) + ",\"lo\":" + textOf(r.minV) + ",\"hi\":" + textOf(r.maxV) + ",\"step\":" + textOf(r.step) +
               ",\"unit\":" + quoted(r.unit) + ",\"values\":" + values + "],\"names\":" + names + "]}";
    }
    gJson = out + "]";
    return gJson.c_str();
}

void onair_radio_setting_set(const char* key, const char* value) {
    App& a = appRunApp();
    const DeviceInfo& d = a.devices[(size_t)a.devIdx];
    for (const dect2::RadioSetting& r : d.settings) {
        if (r.key != key) continue;
        a.tune.radio[r.key] = value;
        saveRadioSettings(a);
        if (!a.engine.running()) return;
        if (r.restart) startReceiver(a); else a.engine.retune(a.tune);
        return;
    }
}

bool onair_mode_select_named(const char* name) {
    App& a = appRunApp();
    for (const auto& m : allModes()) {
        if (strcasecmp(m.name, name) && !(m.sub && !strcasecmp(m.sub, name))) continue;
        selectMode(a, m.family, m.subId);
        return true;
    }
    return false;
}

void onair_source_select_named(const char* source) {
    App& a = appRunApp();
    const bool test = !strcmp(source, "test");
    for (int i = 0; i < (int)a.devices.size(); i++)
        if (test ? a.devices[(size_t)i].kind == DeviceInfo::Synthetic : a.devices[(size_t)i].isNetwork()) { a.devIdx = i; return; }
}

const char* onair_verify_line(void) {
    App& a = appRunApp();
    if (a.engine.player().selected() >= 0) {
        const dect2::PlayerStats st = a.engine.player().stats();
        gVideoStatus = st.videoCodec + " " + std::to_string(st.width) + "x" + std::to_string(st.height) + " " + st.audioCodec + " hw=" + (st.hardware ? "1" : "0") + " decoded=" + std::to_string(st.decoded);
    }
    const std::string json = onair::resultsJson(a.rx, a.engine.running());
    char head[200];
    snprintf(head, sizeof head, " running=%d std=%d audioSec=%.1f videoFrames=%llu services=%zu tsPackets=%llu rate=%.2f json=", a.engine.running() ? 1 : 0, a.rx.standard,
             dect2::audioIosPlayedFrames() / 48000.0, (unsigned long long)gVideoFrames, a.ts.services.size(), (unsigned long long)a.ts.totalPackets, a.engine.sampleRate() / 1e6);
    gJson = head + std::string("[") + gVideoStatus + "] " + json.substr(0, 900);
    return gJson.c_str();
}

const char* onair_status_json(void) {
    App& a = appRunApp();
    std::string mode;
    for (const auto& m : allModes()) if (modeSelected(a, m)) mode = m.name;
    const std::string source = a.devIdx >= 0 && a.devIdx < (int)a.devices.size() ? a.devices[(size_t)a.devIdx].name : "";
    gStatus = "{\"running\":" + std::string(a.engine.running() ? "true" : "false") + ",\"mhz\":" + std::to_string(a.freqMhz) + ",\"mode\":\"" +
              dect2::jsonEscape(mode) + "\",\"source\":\"" + dect2::jsonEscape(source) + "\",\"volume\":" + std::to_string(a.volume) +
              ",\"muted\":" + (a.muted ? "true" : "false") + ",\"family\":" + std::to_string(a.family) + "}";
    return gStatus.c_str();
}

}   // extern "C"
