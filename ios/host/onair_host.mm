// The iOS side of app/main.cpp: the C API of onair_host.h over appRunInit / appRunFrame, touch to ImGuiIO, the pages.
#include "onair_host.h"
#include "app.h"
#include "main_internal.h"
#include "imgui_internal.h"
#include "ui/touch.h"
#include "ui/settings_table.h"
#include "gfx/colormap.h"
#include "results_json.h"
#include "platform/power.h"
#include "dect2/common/thread_name.h"
#include "dect2/net/netradio.h"
#include "dect2/net/remote_api.h"
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#include <cfloat>
#include <string>
#include <vector>

extern "C" void onair_shim_geometry(int w, int h, int fbW, int fbH, float scale);   // glfw_shim.mm
namespace gfx { void setHostLayer(CAMetalLayer* layer); void setBackground(bool on); }  // gfx_metal.mm
namespace power { void setHostOccluded(bool on); }                                     // ios/platform/power_ios.mm
void routeTab(App& a, const std::string& name);                                     // ui/main_tabs.cpp

namespace dect2 { void audioIosRecent(float* stereo, int frames); }                   // audioout_ios.mm
bool settingsIsBound(const settings::Info& i);                                       // ui/settings_window.cpp
settings::Val settingsRead(App& a, const settings::Info& i);
void settingsWrite(App& a, const settings::Info& i, const settings::Val& v);

namespace {
constexpr int kFamilyFm = 5;
OnAirPage gPage = ONAIR_PAGE_TOUCH_SHELL;
bool gBackground = false, gStarted = false;
std::string gStatus, gJson;

std::string quoted(const std::string& s) { return "\"" + dect2::jsonEscape(s) + "\""; }
std::string textOf(double v) { return dect2::jsonNum(v); }

// settings with no meaning on iOS
bool settingHidden(const settings::Info& i) { return i.cat == settings::kPlugins || i.cat == settings::kNetwork; }

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
            ",\"rdsOk\":" + textOf(f.rdsBlockOkPct) + ",\"traffic\":" + (f.trafficProgram ? "true" : "false") + "}";
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
