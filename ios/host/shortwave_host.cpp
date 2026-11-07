// Shortwave for the native screen: the decoder keys and the broadcast bands. pressDecoder is app/shortwave/shortwave_ui.cpp's, which is ImGui-side and private.
#include "onair_host.h"
#include "app.h"
#include "main_internal.h"
#include "dect2/general/general_rx.h"
#include "dect2/general/swbc.h"
#include "dect2/net/remote_api.h"
#include "dect2/shortwave/shortwave_route.h"
#include "dect2/shortwave/shortwave_rx.h"
#include "dect2/shortwave/shortwave_tel.h"
#include <string>

using namespace dect2;
using swr::Dec;

extern "C" {

const char* onair_sw_json(void) {
    static std::string json;
    App& a = appRunApp();
    ShortwaveReceiver& r = a.engine.shortwave();
    json = "{\"auto\":" + std::string(r.autoOn() ? "true" : "false") + ",\"decoders\":[";
    int n = 0;
    const swr::DecoderInfo* table = swr::decoderTable(n);
    for (int i = 0; i < n; i++) {
        json += std::string(i ? "," : "") + "{\"id\":" + std::to_string((int)table[i].id) + ",\"name\":\"" + jsonEscape(table[i].name) + "\",\"group\":\"" + jsonEscape(table[i].group) +
                "\",\"on\":" + (r.decoderActive(table[i].id) ? "true" : "false") + ",\"picture\":" + (table[i].out == swr::Out::Picture ? "true" : "false") + "}";
    }
    json += "],\"bands\":[";
    size_t count = 0;
    const SwBand* bands = swBroadcastBands(count);
    for (size_t i = 0; i < count; i++) json += std::string(i ? "," : "") + "{\"name\":\"" + jsonEscape(bands[i].name) + "\",\"khz\":" + std::to_string(swBandCentreKhz(bands[i])) + "}";
    json += "]}";
    return json.c_str();
}

void onair_sw_press(int id) {
    if (id < 0 || id >= swr::kDecCount) return;
    ShortwaveReceiver& r = appRunApp().engine.shortwave();
    const Dec d = (Dec)id;
    if (r.decoderActive(d)) { r.stopDecoder(d); return; }
    r.startDecoder(d);
    const int current = generalApiDemod();
    if (d == Dec::Cw) {
        if (current != GenCw && current != GenUsb && current != GenLsb) { generalApiSetDemod(GenCw); generalApiSetWidthHz(500); }
    } else if (d != Dec::TimeSig && d != Dec::HfId && d != Dec::Navtex && current != GenUsb && current != GenLsb) {
        generalApiSetDemod(swr::decoderInfo(d).sideband < 0 ? GenLsb : GenUsb);
        generalApiSetWidthHz(2700);
    }
}

void onair_sw_auto(bool on) { appRunApp().engine.shortwave().setAuto(on); }
void onair_sw_stop_all(void) { appRunApp().engine.shortwave().stopAllDecoders(); }
void onair_sw_tune_khz(double khz) { App& a = appRunApp(); generalSetListenHz(a, khz * 1e3); }

}   // extern "C"
