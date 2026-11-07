// The C API the SwiftUI shell calls (bridging header). Everything here runs on the main thread.
#pragma once
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    ONAIR_PAGE_RECEIVER = 0,   // the spectrum and waterfall (overviewTab)
    ONAIR_PAGE_MODE,           // mainTabs(): the current mode's tabs, or its Simple view
    ONAIR_PAGE_TUNER,          // toolbarParts(Tuner | Decoder), source options, radio settings
    ONAIR_PAGE_GAIN,           // toolbarParts(Gain)
    ONAIR_PAGE_LIST,           // rightPanel(): stations, services, aircraft ...
    ONAIR_PAGE_ANALYSIS,       // constellationsTab()
    ONAIR_PAGE_SETTINGS,       // settingsWindow()
    ONAIR_PAGE_TOUCH_SHELL,    // the whole touch shell, unchanged
    ONAIR_PAGE_NONE            // nothing drawn: the receiver logic keeps running behind the native screens
} OnAirPage;

// lifecycle
bool onair_start(void* caMetalLayer, const char* resourceDir);   // once, from the first layout (the view has a size)
bool onair_is_started(void);
bool onair_running(void);
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

// network radios, by NetRadio::Type. Tests the connection on a worker, then saves and selects the radio, as the
// desktop's Network radios window does. Stops the receiver first, because a radio is only picked while stopped.
void onair_net_password(const char* password);                     // a KiwiSDR's, used by the next onair_net_connect
void onair_net_connect(int type, const char* host, int port);
bool onair_net_busy(void);
const char* onair_net_error(void);                               // "" when the last attempt worked

// the native controls: each calls what the desktop's control calls
void onair_start_stop(void);
void onair_tune_mhz(double mhz);
void onair_set_volume(float volume, bool muted);                 // 0..2, as the desktop's slider
int onair_device_count(void);
const char* onair_device_name(int i);
int onair_device_selected(void);
void onair_device_select(int i);
int onair_mode_count(void);
const char* onair_mode_name(int i);
const char* onair_mode_group(int i);
const char* onair_mode_blurb(int i);
int onair_mode_family(int i);
bool onair_mode_is_selected(int i);
void onair_mode_select(int i);

// settings, from app/ui/settings_table.h: a JSON array of rows; Choice is set by the index of the choice
const char* onair_settings_json(void);
void onair_setting_set(const char* key, double value);
void onair_setting_set_text(const char* key, const char* value);

// gain and the selected radio's own settings (DeviceInfo::settings)
const char* onair_gain_json(void);
void onair_gain_set(double db);
void onair_agc_set(bool on);
void onair_iq_fix_set(bool iq);
void onair_dc_mode_set(int mode);                                // 0 leave, 1 remove, 2 tune beside it
const char* onair_radio_settings_json(void);
void onair_radio_setting_set(const char* key, const char* value);

// native spectrum: true when a new line was copied, decimated to n bins of dBFS.
// meta: centre Hz, span Hz, spectrum min dB, spectrum max dB, waterfall min dB, waterfall max dB
bool onair_spectrum(float* bins, int n, double* meta);
void onair_colormap(unsigned* rgba, int n);                      // OnAir's selected waterfall colours, 0xAABBGGRR
void onair_spectrum_tune(double mhz);                            // what a click on the desktop's spectrum does
void onair_spectrum_scrub(double mhz);                           // an exact frequency, with no channel raster: the decoder moves, the radio only past the capture's edge

// FM: state 0 searching, 1 tracking, 2 locked; station, radio text, programme type, stereo, snrDb, levelDbfs, rds, rdsOk, traffic
const char* onair_fm_json(void);

// scopes
void onair_audio_recent(float* stereo, int frames);              // the last frames played, interleaved, oldest first; about 48 kHz
int onair_fm_multiplex(float* db, int maxPoints, float* maxHz);  // the FM multiplex spectrum: points written
int onair_fm_rds_symbols(float* xy, int maxPoints);              // recent RDS symbols, x y pairs: points written

// TV. Services, stream health and the playing service as JSON; picture planes stay valid until the next call of onair_video_latest
typedef struct {
    int width, height;
    double displayAspect;                // width / height, 0 = unknown
    const unsigned char* y;              // NV12: width * height bytes, tightly packed
    const unsigned char* uv;             // width * (height / 2) bytes
    const unsigned char* rgba;           // instead of y and uv, when a subtitle was burnt in
    bool bt709, fullRange;
} OnAirVideoFrame;
bool onair_video_latest(OnAirVideoFrame* frame);
const char* onair_tv_json(void);
void onair_tv_play(int serviceId);                               // -1 stops
int onair_tv_first_service(void);                                // for testing: a service to play, -1 when none or one is playing
void onair_iptv_open(const char* address);                        // a stream or an M3U playlist from the network
void onair_iptv_play(int index);
void onair_iptv_stop(void);
const char* onair_iptv_json(void);
const char* onair_iq_folder(void);                                 // Documents/Recordings, also seen in the Files app
const char* onair_iq_list_json(void);                              // [{name, path, rate, hz, seconds, mode}]
bool onair_iq_open(const char* path, double rateHz);               // play it, looping; rateHz is for a raw file with no rate in its name
bool onair_iq_record(bool on);
const char* onair_iq_record_json(void);                            // {active, seconds, bytes, dropped, error}
const char* onair_rate_json(void);                                 // {usable, now, chosen, auto, need, rates: [Hz]}
void onair_rate_set(double hz);                                    // the radio's sample rate for this mode, 0 = Auto
const char* onair_sw_json(void);                                   // {auto, decoders: [{id, name, group, on, picture}], bands: [{name, khz}]}
void onair_sw_press(int id);                                       // start or stop a decoder
void onair_sw_auto(bool on);
void onair_sw_stop_all(void);
void onair_sw_tune_khz(double khz);
void onair_options_watch(bool on);                                 // keep reading the current mode's settings
const char* onair_options_json(void);                              // [{id, kind, label, section, value, lo, hi, options, disabled}]
void onair_option_set(unsigned id, const char* value);
bool onair_filter_band(double* lowHz, double* highHz);             // what is being listened to, for the box on the spectrum
void onair_fake_guide(void);                                       // made-up programmes, for testing the guide
void onair_location(double* lat, double* lon);                     // the receiver position, 0,0 when never set
void onair_location_set(double lat, double lon);
const char* onair_converter_json(void);                            // {id, lo, rx1, rx2, rx1lo, rx2lo, presets: [{id, name, custom}]}
void onair_antenna_converter_set(const char* antenna, bool hamItUp);   // "rx1" or "rx2": that antenna has a Ham It Up on it
void onair_antenna_converter_model(const char* antenna, const char* model);   // "plus", "v13", "nano": what it passes
void onair_antenna_converter_lo(const char* antenna, double mhz);  // its oscillator, normally 125
void onair_converter_set(const char* id, double loMhz);            // loMhz is for the custom one
const char* onair_bearing_json(void);                              // {ok, phaseDeg, coherence, hz}: RX2 against RX1 on the filter band
const char* onair_auto_message(void);                              // what TV (auto) or Digital voice (auto) is doing, empty when neither runs
void onair_tv_play_file(const char* path);                        // a recorded .ts through the demux and the player, at its own pace
void onair_tv_bandwidth(double mhz);                             // 6, 7 or 8; 0 automatic
const char* onair_epg_json(int serviceId);
// Teletext: 25 rows of 40 cells. Each is bits 0-20 the character or the mosaic's six cells, 21-23 foreground, 24-26 background, 27 mosaic, 28-29 double height, 30 separated.
// links: red, green, yellow, cyan pages. False when the page has not arrived.
bool onair_teletext_page(int page, unsigned* cells, int* links);
const char* onair_teletext_pages_json(void);

// channels of the current mode's region plan and its known frequencies; the plan is OnAir's, "" follows the phone's region
const char* onair_channels_json(void);
void onair_channel_plan_set(const char* planId);
void onair_channel_pick(double mhz, double bandwidthMhz);        // tunes, and sets the plan's channel width where the mode has one

// The general receiver (SSB, CW, AM, FM). Levels in dBFS; demod as GeneralDemod: 0 NFM, 1 WFM, 2 AM, 3 USB, 4 LSB, 5 CW
const char* onair_general_json(void);
void onair_general_set(int demod, double widthHz);

// Transmit, through OnAir's transmit session. mode: "" is the current mode. iqPath non-empty writes the signal to that file instead of the radio.
// Returns false with err in plain words. Nothing is sent unless the radio can transmit. seconds: one pass, 0 until stopped.
typedef struct {
    double mhz, gainDb, seconds;
    const char* callsign;
    const char* grid;
    const char* text;
    const char* dest;
    int kind;                            // FT8: 0 CQ, 1 report, 2 free text
    int wpm;
    bool microphone;                     // the voice comes from the microphone
    const char* iqPath;
} OnAirTxRequest;
bool onair_tx_supported(void);                                   // the current mode has a transmitter
bool onair_tx_start(const OnAirTxRequest* request, char* err, int errSize);
void onair_tx_stop(void);
const char* onair_tx_json(void);                                 // running, seconds, peak, failed, error

// Broadcast: play a service from the Services table (DAB: its sub-channel, DRM: its index); the newest slideshow picture, RGBA, valid until the next call
void onair_broadcast_select(int subchannel);
bool onair_slide_latest(const unsigned char** rgba, int* width, int* height);

// the active mode's newest picture (weather satellites, SSTV ...), RGBA, valid until the next call. seq changes with the picture
bool onair_image_latest(const unsigned char** rgba, int* width, int* height, unsigned long long* seq);
bool onair_jpeg_latest(const unsigned char** bytes, int* size);   // SSDV sends JPEG

// the active mode's decoded results: summary, cards and tables
const char* onair_results_json(void);

// testing from the Mac: pick a mode by name and a source ("test", or the first network radio), and one line of what the decoder produced
bool onair_mode_select_named(const char* name);
void onair_source_select_named(const char* source);
const char* onair_verify_line(void);

// state for the native strip: running, mhz, mode, source, volume, muted
const char* onair_status_json(void);

#ifdef __cplusplus
}
#endif
