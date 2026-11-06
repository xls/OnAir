// The iOS side of app/main.cpp: the C API of onair_host.h over appRunInit / appRunFrame, touch to ImGuiIO, the pages.
#include "onair_host.h"
#include "app.h"
#include "main_internal.h"
#include "imgui_internal.h"
#include "ui/touch.h"
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

namespace {
constexpr int kFamilyFm = 5;
OnAirPage gPage = ONAIR_PAGE_TOUCH_SHELL;
bool gBackground = false, gStarted = false;
std::string gStatus;

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

const char* onair_status_json(void) {
    App& a = appRunApp();
    std::string mode;
    for (const auto& m : allModes()) if (modeSelected(a, m)) mode = m.name;
    const std::string source = a.devIdx >= 0 && a.devIdx < (int)a.devices.size() ? a.devices[(size_t)a.devIdx].name : "";
    gStatus = "{\"running\":" + std::string(a.engine.running() ? "true" : "false") + ",\"mhz\":" + std::to_string(a.freqMhz) + ",\"mode\":\"" +
              dect2::jsonEscape(mode) + "\",\"source\":\"" + dect2::jsonEscape(source) + "\",\"volume\":" + std::to_string(a.volume) +
              ",\"muted\":" + (a.muted ? "true" : "false") + "}";
    return gStatus.c_str();
}

}   // extern "C"
