// Writes SigMF recordings for the modes OnAir has no built-in test signal for, from the generators their unit tests use. Copy them to the
// simulator's Documents/Recordings and play them with --iq <name>.sigmf-meta. Built by hand against the desktop's libdect2core.a, see PLAN.md.
#include "dect2/dgps/dgps_rx.h"
#include "dect2/eloran/eloran_gen.h"
#include "dect2/edacs/edacs_gen.h"
#include "dect2/engine/modes.h"
#include "dect2/fusion/fusion_gen.h"
#include "dect2/ltr/ltr_proto.h"
#include "dect2/mpt1327/mpt1327_gen.h"
#include "dect2/p25p2/p25p2_gen.h"
#include "dect2/source/iq_file.h"
#include <cmath>
#include <complex>
#include <cstdio>
#include <string>
#include <vector>
using namespace dect2;
using IQ = std::vector<std::complex<float>>;

static std::string gDir;

static void save(const char* id, double rate, const IQ& iq, double centreMhz = 0) {
    const ModeTuning* t = modeTuningById(id);
    const std::string base = gDir + "/test-" + id;
    FILE* f = fopen((base + ".sigmf-data").c_str(), "wb");
    fwrite(iq.data(), sizeof(iq[0]), iq.size(), f);
    fclose(f);
    std::string err;
    writeSigmfMeta(base + ".sigmf-meta", FileFormat::CF32, false, rate, (centreMhz > 0 ? centreMhz : t ? t->defMhz : 100) * 1e6, 0, id, err);
    printf("%s: %.1f s at %.0f ksps, centre %.3f MHz %s\n", id, iq.size() / rate, rate / 1e3, (t ? t->defMhz : 100.0), err.c_str());
}

static void gap(IQ& iq, double seconds, double rate) { iq.insert(iq.end(), (size_t)(seconds * rate), {0.0005f, 0}); }

int main(int argc, char** argv) {
    gDir = argc > 1 ? argv[1] : ".";
    {   // Yaesu Fusion: two callers in turn
        const double fs = 480000;
        IQ iq;
        for (int r = 0; r < 4; r++) {
            fusion::GenParams p;
            p.dt = r & 1;
            p.commFrames = 12;
            p.src = r & 1 ? "LY1ABC" : "VK2XYZ";
            p.dest = "CQCQCQ";
            p.slow = "33.9S 151.2E";
            std::vector<uint8_t> bits;
            fusion::genTransmissionBits(p, bits);
            const IQ one = fusion::modulateC4fm(bits, fs, 0, 0.5f);
            iq.insert(iq.end(), one.begin(), one.end());
            gap(iq, 0.5, fs);
        }
        save("fusion", fs, iq);
    }
    {   // P25 Phase 2: a clear call and an encrypted one
        P25p2GenConfig c;
        c.rate = 480000;
        c.snrDb = 40;
        c.superframes = 60;
        P25p2GenCall a, b;
        a.channel = 1; a.startSf = 1; a.nSf = 20; a.src = 1234567; a.group = 1001;
        b.channel = 2; b.startSf = 5; b.nSf = 20; b.src = 777; b.group = 2002; b.algId = 0x84;
        c.calls = {a, b};
        save("p25p2", c.rate, p25p2Signal(c));
    }
    {   // MPT 1327: channel grants on a control channel
        using namespace mpt1327;
        const double fs = 480000;
        std::vector<uint64_t> msgs;
        for (int i = 0; i < 400; i++) {
            msgs.push_back(makeAloha(1, 100 + i % 7, 0, 0));
            if (i % 5 == 0) msgs.push_back(makeGtc(1, 200 + i % 5, 0, 300 + i % 9, 250 + i % 11));
        }
        const std::vector<float> audio = ffskAudio(controlChannelBits(20001, msgs), fs, false, 0.45f);
        save("mpt1327", fs, fmModulate(audio, fs, 2500, 0));
    }
    {   // DGPS beacon: station id and corrections
        const double fs = 96000;
        std::vector<uint8_t> bits;
        for (int i = 0; i < 40; i++) bits.push_back(i & 1);
        for (int r = 0; r < 30; r++) {
            dgps::Header h;
            h.type = 3; h.stationId = 321; h.zcount = 100 + r * 50; h.seq = r & 7; h.health = 0;
            const std::vector<uint32_t> body = dgps::bodyType3(-4646000, 2553000, -3534000);
            h.length = (int)body.size();
            const std::vector<uint8_t> m = dgps::encodeMessage(h, body);
            bits.insert(bits.end(), m.begin(), m.end());
            for (int i = 0; i < 60; i++) bits.push_back(i & 1);
        }
        save("dgps", fs, dgps::modulate(bits, fs, 0, 0.5f, 1.0, 200));
    }
    {   // LTR: subaudible words under a voice tone, six radios in turn
        const double fs = 480000;
        std::vector<uint8_t> bits;
        for (int i = 0; i < 40; i++) bits.push_back(i & 1);
        const int words[6][5] = {{0, 3, 3, 17, 5}, {0, 5, 1, 101, 7}, {1, 12, 12, 254, 2}, {0, 0, 8, 255, 9}, {0, 7, 2, 33, 20}, {0, 19, 19, 200, 1}};
        for (int r = 0; r < 20; r++) for (const auto& w : words) {
            ltr::Word x;
            x.area = w[0]; x.gotoCh = w[1]; x.home = w[2]; x.id = w[3]; x.freeCh = w[4];
            x.chk = ltr::checksum(x);
            const auto e = ltr::encodeWord(x);
            bits.insert(bits.end(), e.begin(), e.end());
            for (int i = 0; i < 12; i++) bits.push_back((i * 7 + r) & 1);
        }
        save("ltr", fs, ltr::modulate(bits, fs, 0, 600.0, 0.5f, 1000.0, 1500.0));
    }
    {   // EDACS: a control channel announcing group calls
        EdacsGenConfig c;
        c.rate = 480000;
        c.centreHz = c.controlHz = 856000000;
        c.durSec = 16;
        for (int i = 0; i < 8; i++) c.lcnFreqHz.push_back(856000000 + i * 25000.0);
        for (int i = 0; i < 4; i++) {
            EdacsGenCall call;
            call.lcn = 3 + i;
            call.gid = 700 + i;
            call.lid = 4321 + i;
            call.startSec = 1 + i * 3.5;
            call.endSec = call.startSec + 2.5;
            c.calls.push_back(call);
        }
        save("edacs", c.rate, edacsSystemSignal(c));
    }
    {   // Marine VHF: a tone on channel 16, 156.800 MHz, 12.5 kHz below the centre
        const double fs = 250000;
        std::vector<float> audio((size_t)(fs * 2), 0.f);
        for (size_t i = 0; i < (size_t)(fs * 12); i++) audio.push_back((float)(0.6 * std::sin(2 * M_PI * 1000 * i / fs)));
        audio.insert(audio.end(), (size_t)(fs * 2), 0.f);
        IQ iq = mpt1327::fmModulate(audio, fs, 3000, -12500);
        for (size_t i = 0; i < (size_t)(fs * 2); i++) iq[i] = {0.0005f, 0};
        for (size_t i = iq.size() - (size_t)(fs * 2); i < iq.size(); i++) iq[i] = {0.0005f, 0};
        save("marinevhf", fs, iq, 156.8125);
    }
    {   // Loran-C: a chain of three stations
        loran::GenParams g;
        g.fs = 400000;
        g.seconds = 12;
        g.griUs = 99600;
        g.carrierHz = 0;
        g.snrDb = 30;
        g.stations = {{true, 0.0, 0.4}, {false, 23456.7, 0.35}, {false, 41234.5, 0.3}};
        save("eloran", g.fs, loran::generateLoran(g));
    }
}
