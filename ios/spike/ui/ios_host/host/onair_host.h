// The C API the SwiftUI shell calls (bridging header). Everything here runs on the main thread.
#pragma once
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    ONAIR_PAGE_RECEIVER = 0,   // the spectrum and waterfall (overviewTab)
    ONAIR_PAGE_MODE,           // mainTabs(): the current mode's tabs, or its Simple view
    ONAIR_PAGE_TUNER,          // toolbarParts(Source | Tuner | Decoder), source options, radio settings
    ONAIR_PAGE_LIST,           // rightPanel(): stations, services, aircraft ...
    ONAIR_PAGE_ANALYSIS,       // constellationsTab()
    ONAIR_PAGE_SETTINGS,       // settingsWindow()
    ONAIR_PAGE_TOUCH_SHELL     // the whole touch shell, unchanged (the fallback)
} OnAirPage;

// lifecycle
bool onair_start(void* caMetalLayer, const char* resourceDir);   // once, from the first layout (the view has a size)
void onair_frame(void);                                          // MTKViewDelegate draw, and the background timer
void onair_set_background(bool background);                      // scenePhase: no Metal work while true; flushes the settings
void onair_flush(void);                                          // settings and results to disk (may be killed after this)
double onair_wanted_interval(void);                              // seconds the next frame may wait (pace::interval)

// geometry: size in points, scale in pixels per point
void onair_resize(int widthPt, int heightPt, float scale);

// pages
void onair_set_page(OnAirPage page);
void onair_open_tab(const char* name);                           // a main tab by its name (routeTab)
int onair_tab_count(void);                                       // the main tabs of the last frame
const char* onair_tab_name(int i, bool* open);

// input (points)
void onair_touch(int id, float x, float y, int phase);           // 0 began, 1 moved, 2 ended, 3 cancelled
void onair_text(const char* utf8);
void onair_key_backspace(void);
void onair_key_enter(void);
bool onair_wants_keyboard(void);                                 // io.WantTextInput
int onair_keyboard_kind(void);                                   // 0 text, 1 decimal

// state for the native bar
const char* onair_status_json(void);                             // running, frequency, mode name

#ifdef __cplusplus
}
#endif
