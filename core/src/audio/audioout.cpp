#include "audioout_impl.h"
#include "dect2/audio/audio_rec.h"
#include "dect2/audio/clip_ring.h"
#include "dect2/transcribe/audio_tap.h"
#include <algorithm>
#include <cstring>
#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <string>
#include <chrono>
#include <mutex>
#ifdef __linux__
#include <unistd.h>
#include <sys/stat.h>
#endif

namespace dect2 {

// DECT2_MUTE=1: everything plays silence (the device still runs, so the timing that tests and the player rely on is unchanged). The tests
// set it (CMakeLists.txt): the engine tests of FM, DAB, DRM, ATSC and the others otherwise played their test signals out loud.
static const bool kForceMute = [] { const char* e = getenv("DECT2_MUTE"); return e && *e && *e != '0'; }();

static std::atomic<int64_t> gModeWriteMs{INT64_MIN / 4};
static int64_t nowMs() { return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
int AudioOut::msSinceModeWrite() { const int64_t d = nowMs() - gModeWriteMs.load(std::memory_order_relaxed); return d > 1000000000 ? 1000000000 : (int)d; }
std::vector<std::string> AudioOut::devices() { return audioListOutputs(); }
static std::mutex gDefDevMx;
static std::string gDefDev;
void AudioOut::setDefaultDevice(const std::string& name) { std::lock_guard<std::mutex> g(gDefDevMx); gDefDev = name; }
std::string AudioOut::defaultDevice() { std::lock_guard<std::mutex> g(gDefDevMx); return gDefDev; }

void AudioOut::Impl::render(float* out, uint32_t nFrames) {
    if (flushReq.exchange(false)) { r.store(w.load()); playing = false; leveler.reset(); }
    const uint64_t wr = w.load(std::memory_order_acquire), rd = r.load(std::memory_order_relaxed);
    const uint64_t avail = wr - rd;
    if (!playing) {
        if ((int)avail >= startThreshold.load()) { playing = true; startThreshold = 38400; } // resume after an underrun once 0.8 s are buffered
    }
    uint32_t n = 0;
    if (playing) {
        n = (uint32_t)std::min<uint64_t>(avail, nFrames);
        const float vol = muted.load() || kForceMute ? 0.f : volumeTaper(volume.load());
        const size_t mask = frames - 1;
        for (uint32_t i = 0; i < n; i++) {
            const size_t k = (size_t)((rd + i) & mask) * 2;
            out[2 * i] = ring[k];
            out[2 * i + 1] = ring[k + 1];
        }
        leveler.process(out, (int)n);
        if (tap) tap(out, n);
        for (uint32_t i = 0; i < 2 * n; i++) out[i] *= vol;
        r.store(rd + n, std::memory_order_release);
        played.fetch_add(n);
        if (n < nFrames) { underruns++; playing = false; leveler.reset(); }
    }
    if (n < nFrames) memset(out + 2 * n, 0, (size_t)(nFrames - n) * 2 * sizeof(float));
}

AudioOut::AudioOut() : p_(new Impl) {
    p_->frames = 1 << 18; // 262144 frames ~ 5.5 s at 48 kHz
    p_->ring.assign(p_->frames * 2, 0.f);
}
AudioOut::~AudioOut() { stop(); }

bool AudioOut::start(int rate) {
    if (running_) return true;
    rate_ = rate;
    // the device: the one set for this output, else the one chosen for the current mode (audio_control.h); one that has disappeared falls back to the default
    p_->device = actl::audioPickDevice(audioListOutputs(), device_.empty() ? defaultDevice() : device_);
#ifdef __linux__
    // run with sudo, the sound server of the user who ran sudo is not found (issue #67): point PulseAudio/PipeWire at it
    if (geteuid() == 0 && !getenv("PULSE_SERVER") && !getenv("XDG_RUNTIME_DIR")) {
        if (const char* uid = getenv("SUDO_UID"); uid && *uid) {
            const std::string dir = std::string("/run/user/") + uid, sock = dir + "/pulse/native";
            struct stat st{};
            if (stat(sock.c_str(), &st) == 0) {
                setenv("PULSE_SERVER", ("unix:" + sock).c_str(), 0);
                setenv("XDG_RUNTIME_DIR", dir.c_str(), 0);
                fprintf(stderr, "audio: running as root, using the sound server of user %s (%s)\n", uid, sock.c_str());
            }
        }
    }
#endif
    p_->cleanup.prepare(rate);
    p_->control.prepare(rate);
    { const int lat = AudioControlConfig::global().get().latencyMs; if (lat != 300) p_->startThreshold = std::max(480, rate / 1000 * lat); }   // the user's choice; modes that set their own threshold after start() keep it
    p_->vinv.prepare(rate);
    if (!audioBackendStart(p_.get(), rate)) return false;
    running_ = true;
    return true;
}

void AudioOut::stop() {
    if (!running_) return;
    audioBackendStop(p_.get());
    running_ = false;
}

int AudioOut::write(const float* s, int frames) {
    const uint64_t w = p_->w.load(std::memory_order_relaxed), r = p_->r.load(std::memory_order_acquire);
    const int space = (int)(p_->frames - (w - r));
    const int n = std::min(frames, space);
    const size_t mask = p_->frames - 1;
    const AudioCleanupConfig& cc = AudioCleanupConfig::global();
    const bool clean = !monitor_ && running_;   // the chain returns the input itself while it is off (and fades itself out when switched off)
    for (int off = 0; off < n;) {
        const int m = std::min(n - off, (int)AudioCleanup::kMaxChunk);
        const float* raw = s + 2 * (size_t)off;
        const float* src = raw;
        bool active = false, invActive = false, recOpen = true;
        if (clean) {
            // voice inversion first (analog voice only, off by default), then the cleanup; decoders / clips / transcripts keep `raw`
            if (m <= VoiceInversion::kMaxChunk) src = p_->vinv.process(raw, m, p_->invBuf, &invActive);
            const float* cleaned = p_->cleanup.process(src, m, p_->cleanBuf, &active);
            src = cleaned;
            active = active || invActive;
            // audio control: filters, EQ, notch, AGC, squelch (off: the same pointer back)
            bool ctlActive = false, ctlOpen = true;
            src = p_->control.process(src, m, p_->ctlBuf, &ctlActive, &ctlOpen);
            active = active || ctlActive;
            recOpen = ctlOpen;
        }
        for (int i = 0; i < m; i++) {
            const size_t k = (size_t)((w + off + i) & mask) * 2;
            p_->ring[k] = src[2 * i]; p_->ring[k + 1] = src[2 * i + 1];
        }
        // "Record audio": the raw sound, or the cleaned one when asked; with "skip silence" nothing while the gate holds the sound off
        // with "record only when the squelch is open" nothing is recorded while it is closed
        const bool recGate = !(recOpen || !AudioControlConfig::global().recordOnlyOpen.load(std::memory_order_relaxed));
        if (recGate) {}
        else if (active && cc.recCleaned.load(std::memory_order_relaxed)) {
            if (!(cc.skipSilence.load(std::memory_order_relaxed) && !p_->cleanup.gateOpen())) AudioRecorder::offer(this, src, m, rate_);
        } else AudioRecorder::offer(this, raw, m, rate_);
        AudioClipRing::offer(this, raw, m, rate_);   // radio clips: the last seconds, kept in a ring
        AudioTap::offer(this, raw, m, rate_);        // live transcripts of the modes that have no channel audio of their own
        off += m;
    }
    p_->w.store(w + n, std::memory_order_release);
    p_->written.fetch_add(n);
    if (!monitor_ && !p_->muted.load(std::memory_order_relaxed) && n > 0) gModeWriteMs.store(nowMs(), std::memory_order_relaxed);   // the mode is playing: a monitor yields
    return n;
}

void AudioOut::flush() { p_->flushReq = true; }
int AudioOut::bufferedFrames() const { return p_->flushReq.load() ? 0 : (int)(p_->w.load() - p_->r.load()); }   // audio about to be thrown away does not count
uint64_t AudioOut::writtenFrames() const { return p_->written.load(); }
uint64_t AudioOut::playedFrames() const { return p_->played.load(); }
void AudioOut::setVolume(float v) { p_->volume = v; }
void AudioOut::setMuted(bool m) { p_->muted = m; }
int AudioOut::underruns() const { return p_->underruns.load(); }
bool AudioOut::playing() const { return p_->playing.load(); }
void AudioOut::setStartThreshold(int f) { p_->startThreshold = f; }

} // namespace dect2
