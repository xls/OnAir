// The C interface of ios/core/include/onair_core.h. One engine for the whole app. Receive only.
#include "onair_core.h"
#include <cstdio>
#include <mutex>
#include <string>

#include "dect2/engine/engine.h"

namespace dect2 { uint64_t audioIosPlayedFrames(); }   // audioout_ios.mm

using namespace dect2;

namespace {

constexpr int kFmStandard = 7;   // the engine's number for FM broadcast

struct Core {
    Engine eng;
    std::mutex mu;   // start and stop one at a time
    uint64_t specSeq = 0, frames = 0;
    double rmsDbfs = -120;
};
Core* gCore = nullptr;

void copyOut(const std::string& s, char* out, int size) {
    if (out && size > 0) std::snprintf(out, (size_t)size, "%s", s.c_str());
}

} // namespace

void onair_core_init(const char* dataDir) {
    if (gCore) return;
    gCore = new Core();
    gCore->eng.setSpectrumEnabled(true);
    if (dataDir && *dataDir) gCore->eng.setResultsDir(dataDir);
}

bool onair_core_start_fm_test(char* err, int errSize) {
    std::lock_guard<std::mutex> lk(gCore->mu);
    Engine& e = gCore->eng;
    if (e.running()) e.stop();
    DeviceInfo dev;
    dev.kind = DeviceInfo::Synthetic;
    dev.name = "Test signal";
    TuneSettings tune;
    tune.centerHz = 100e6;
    tune.sampleRate = 4e6;
    tune.bandwidthMhz = 0.25;
    tune.synth.mode = kFmStandard;
    e.setStandard(kFmStandard);
    gCore->specSeq = gCore->frames = 0;
    const bool ok = e.start(dev, tune, FileOptions());
    if (!ok) copyOut(e.sourceNote().empty() ? "could not start the source" : e.sourceNote(), err, errSize);
    return ok;
}

void onair_core_stop(void) {
    std::lock_guard<std::mutex> lk(gCore->mu);
    gCore->eng.stop();
}

bool onair_core_running(void) { return gCore && gCore->eng.running(); }

void onair_core_set_volume(float volume01) {
    gCore->eng.fm().setVolume(volume01);
    gCore->eng.fm().setMuted(volume01 <= 0);
}

void onair_core_status(char* out, int outSize) {
    Core& c = *gCore;
    SpectrumFrame f;
    while (c.eng.latestSpectrum(f, c.specSeq)) {
        c.specSeq = f.seq;
        c.frames++;
        c.rmsDbfs = f.stats.rmsDbfs;
    }
    RxTelemetry rx;
    const bool have = c.eng.latestRx(rx, 0);
    const bool locked = have && rx.fm.state == 2;
    char s[260];
    std::snprintf(s, sizeof s, "%s  spectrum frames %llu  level %.1f dBFS  FM %s  SNR %.0f dB  stereo %s  station %s  audio %.1f s",
                  c.eng.running() ? "running" : "stopped", (unsigned long long)c.frames, c.rmsDbfs, locked ? "locked" : "searching",
                  have ? rx.fm.snrDb : 0.f, have && rx.fm.stereo ? "yes" : "no", have ? rx.fm.psName.c_str() : "", audioIosPlayedFrames() / 48000.0);
    copyOut(s, out, outSize);
}
