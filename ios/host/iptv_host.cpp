// Internet TV for the native screen: the same reader and player as app/iptv/iptv_ui.cpp, which is ImGui-only and keeps its state private.
// An address is either one stream or a playlist; the bytes go to the Player as transport stream packets.
#include "onair_host.h"
#include "app.h"
#include "main_internal.h"
#include "dect2/common/thread_name.h"
#include "dect2/net/remote_api.h"
#include "dect2/tv/iptv.h"
#include "dect2/tv/ts.h"
#include <atomic>
#include <mutex>
#include <string>
#include <vector>

using namespace dect2;

namespace {

struct IptvHost {
    iptv::Stream stream;
    std::mutex streamLock, stateLock;
    TsDemux demux;
    TsSnapshot snap;
    std::chrono::steady_clock::time_point snapAt;
    bool selected = false;
    std::vector<iptv::Channel> channels;
    std::string message, playing;
    std::atomic<bool> busy{false};
};

IptvHost& host() { static IptvHost* h = new IptvHost; return *h; }

void sink(const uint8_t* p, size_t n, App* a) {
    IptvHost& s = host();
    std::lock_guard<std::mutex> lk(s.streamLock);
    for (size_t i = 0; i < n; i++) s.demux.feed(p + i * 188);
    a->engine.feedPlaybackSubtitles(p, n);
    const auto now = std::chrono::steady_clock::now();
    bool ready = false;
    for (const TsService& v : s.snap.services) ready |= v.havePmt;
    if (!ready || now - s.snapAt > std::chrono::seconds(1)) { s.snap = s.demux.snapshot(); s.snapAt = now; }
    Player& player = a->engine.player();
    if (!s.selected) for (const TsService& v : s.snap.services) if (v.havePmt) {
        player.select(v.id);
        player.setVolume(a->volume);
        s.selected = true;
        break;
    }
    if (player.selected() >= 0) player.push(p, n, s.snap);
}

void stopPlaying(App& a) {
    IptvHost& s = host();
    s.stream.stop();
    std::lock_guard<std::mutex> lk(s.streamLock);
    a.engine.player().select(-1);
    a.engine.setPlayerExternal(false);
    a.engine.teletext().reset();
    s.selected = false;
}

void play(App& a, const std::string& url, const iptv::Channel* channel, const std::string& name) {
    IptvHost& s = host();
    if (channel && channel->drm) {
        std::lock_guard<std::mutex> lk(s.stateLock);
        s.message = "This channel is DRM protected, so it cannot be opened.";
        return;
    }
    stopPlaying(a);
    {
        std::lock_guard<std::mutex> lk(s.streamLock);
        s.demux.reset();
        s.snap = TsSnapshot();
        s.snapAt = {};
    }
    iptv::StreamOptions o;
    if (channel) {
        if (!channel->userAgent.empty()) o.userAgent = channel->userAgent;
        o.referer = channel->referer;
        o.headers = channel->headers;
    }
    a.engine.setPlayerExternal(true);
    a.engine.teletext().reset();
    {
        std::lock_guard<std::mutex> lk(s.stateLock);
        s.playing = name.empty() ? iptv::redactUrl(url) : name;
        s.message.clear();
    }
    App* ap = &a;
    s.stream.start(url, o, [ap](const uint8_t* p, size_t n) { sink(p, n, ap); });
}

bool looksLikePlaylist(const std::string& url) {
    std::string path = url.substr(0, url.find('?'));
    for (char& c : path) c = (char)tolower((unsigned char)c);
    return path.size() > 4 && path.compare(path.size() - 4, 4, ".m3u") == 0;
}

} // namespace

extern "C" void onair_iptv_open(const char* address) {
    App& a = appRunApp();
    IptvHost& s = host();
    const std::string url = iptv::trim(address);
    if (s.busy.exchange(true)) return;
    {
        std::lock_guard<std::mutex> lk(s.stateLock);
        s.message = "Opening…";
    }
    dect2::namedThread("onair-iptv", [&a, &s, url] {
        // .m3u8 is a playlist of channels or one HLS stream: only the text tells which, and a plain stream has no text to fetch
        std::string text;
        iptv::HttpResult result;
        const bool hasText = looksLikePlaylist(url) || url.find(".m3u8") != std::string::npos;
        if (hasText && !iptv::httpGetAll(url, iptv::HttpOptions(), text, result)) {
            std::lock_guard<std::mutex> lk(s.stateLock);
            s.message = result.error.empty() ? "The address did not answer." : result.error;
            s.busy = false;
            return;
        }
        iptv::Playlist list;
        if (hasText) list = iptv::parseM3u(text, url);
        if (hasText && !list.isHlsStream && !list.channels.empty()) {
            std::lock_guard<std::mutex> lk(s.stateLock);
            s.channels = std::move(list.channels);
            s.message.clear();
        } else {
            play(a, url, nullptr, "");
        }
        s.busy = false;
    }).detach();
}

extern "C" void onair_iptv_play(int index) {
    App& a = appRunApp();
    IptvHost& s = host();
    iptv::Channel channel;
    {
        std::lock_guard<std::mutex> lk(s.stateLock);
        if (index < 0 || index >= (int)s.channels.size()) return;
        channel = s.channels[(size_t)index];
    }
    play(a, channel.url, &channel, channel.name);
}

extern "C" void onair_iptv_stop(void) {
    IptvHost& s = host();
    stopPlaying(appRunApp());
    std::lock_guard<std::mutex> lk(s.stateLock);
    s.playing.clear();
}

extern "C" const char* onair_iptv_json(void) {
    static std::string out;
    IptvHost& s = host();
    const iptv::StreamInfo info = s.stream.info();
    std::lock_guard<std::mutex> lk(s.stateLock);
    const std::string message = info.message.empty() ? s.message : info.message;
    out = "{\"busy\":" + std::string(s.busy ? "true" : "false") + ",\"state\":\"" + jsonEscape(s.playing.empty() ? "" : info.state) + "\",\"kind\":\"" + jsonEscape(info.kind) +
          "\",\"message\":\"" + jsonEscape(message) + "\",\"playing\":\"" + jsonEscape(s.playing) + "\",\"mbps\":" + std::to_string(info.measuredBps / 1e6) +
          ",\"buffered\":" + std::to_string(info.bufferedSec) + ",\"channels\":[";
    for (size_t i = 0; i < s.channels.size(); i++) {
        const iptv::Channel& c = s.channels[i];
        if (i) out += ",";
        out += "{\"id\":" + std::to_string(i) + ",\"name\":\"" + jsonEscape(c.name) + "\",\"group\":\"" + jsonEscape(c.group) + "\",\"drm\":" + (c.drm ? "true" : "false") + "}";
    }
    out += "]}";
    return out.c_str();
}
