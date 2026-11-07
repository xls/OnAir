// A two-antenna bearing, with Antenna set to Both: the phase of RX2 against RX1 on the signal in the filter. The two receivers share one LO, so
// that phase holds still. A wave arriving at an angle reaches one antenna first; the phase difference gives the angle (the Swift side does that,
// with the spacing and the calibration). Two antennas cannot tell in front from behind.
#include "onair_host.h"
#include "app.h"
#include "main_internal.h"
#include <atomic>
#include <cmath>
#include <complex>
#include <cstdio>
#include <mutex>
#include <string>
#include <vector>

namespace dect2 { extern std::atomic<void (*)(const cf32*, const cf32*, size_t)> gPlutoDualTap; }

using namespace dect2;

namespace {
constexpr size_t kBlock = 32768;
std::mutex gMu;
std::vector<cf32> gA, gB;
std::string gJson;

void tap(const cf32* a, const cf32* b, size_t n) {
    std::unique_lock<std::mutex> lock(gMu, std::try_to_lock);
    if (!lock.owns_lock()) return;
    n = std::min(n, kBlock);
    gA.assign(a, a + n);
    gB.assign(b, b + n);
}
}   // namespace

extern "C" const char* onair_bearing_json(void) {
    gPlutoDualTap.store(tap);
    App& a = appRunApp();
    double low = 0, high = 0;
    std::vector<cf32> ca, cb;
    { std::lock_guard<std::mutex> lock(gMu); ca = gA; cb = gB; }
    const double rate = a.engine.radioRate();
    if (!a.engine.running() || ca.size() < 4096 || rate <= 0 || !onair_filter_band(&low, &high)) { gJson = "{\"ok\":false}"; return gJson.c_str(); }
    // the filter band brought to zero, then a moving average as wide as the band
    const double offset = (low + high) / 2 - a.engine.captureCentreHz(), step = -2 * M_PI * offset / rate;
    const size_t width = std::clamp<size_t>((size_t)(rate / std::max(high - low, 1000.0)), 1, 512);
    std::complex<double> sumA(0), sumB(0), cross(0);
    double powerA = 0, powerB = 0, phase = 0;
    size_t count = 0;
    for (size_t i = 0; i < ca.size(); i++, phase += step) {
        const std::complex<double> turn(std::cos(phase), std::sin(phase));
        sumA += std::complex<double>(ca[i]) * turn;
        sumB += std::complex<double>(cb[i]) * turn;
        if (++count < width) continue;
        cross += sumA * std::conj(sumB);
        powerA += std::norm(sumA);
        powerB += std::norm(sumB);
        sumA = sumB = 0;
        count = 0;
    }
    const double coherence = powerA > 0 && powerB > 0 ? std::abs(cross) / std::sqrt(powerA * powerB) : 0;
    char text[160];
    snprintf(text, sizeof text, "{\"ok\":true,\"phaseDeg\":%.2f,\"coherence\":%.3f,\"hz\":%.0f}", std::arg(cross) * 180 / M_PI, coherence, (low + high) / 2);
    gJson = text;
    return gJson.c_str();
}
