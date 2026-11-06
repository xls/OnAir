// IQ recordings for the native screens: the folder (Documents/Recordings, also visible in the Files app), playing one and recording the radio.
// Same steps as app/ui/toolbar_source.cpp applyIqFileInfo, which is ImGui-side and static.
#include "onair_host.h"
#include "app.h"
#include "main_internal.h"
#include "gfx/file_vfo.h"
#include "dect2/net/remote_api.h"
#include "dect2/source/iq_file.h"
#include "dect2/source/iq_record.h"
#include <cstdlib>
#include <filesystem>
#include <string>

using namespace dect2;

namespace {
std::string gList, gRecord;

std::string folder() {
    const char* home = getenv("HOME");
    const std::string dir = std::string(home ? home : ".") + "/Documents/Recordings";
    std::error_code ec;
    std::filesystem::create_directories(dir, ec);
    return dir;
}
}   // namespace

extern "C" {

const char* onair_iq_folder(void) {
    static std::string dir;
    dir = folder();
    return dir.c_str();
}

const char* onair_iq_list_json(void) {
    gList = "[";
    for (const RecordingListing& r : listRecordingFiles(folder())) {
        if (gList.size() > 1) gList += ",";
        gList += "{\"name\":\"" + jsonEscape(r.fileName) + "\",\"path\":\"" + jsonEscape(r.path) + "\",\"rate\":" + std::to_string(r.sampleRate) +
                 ",\"hz\":" + std::to_string(r.centerHz) + ",\"seconds\":" + std::to_string(r.seconds) + ",\"mode\":\"" + jsonEscape(r.mode) + "\"}";
    }
    gList += "]";
    return gList.c_str();
}

bool onair_iq_open(const char* path, double rateHz) {
    App& a = appRunApp();
    int file = -1;
    for (int i = 0; i < (int)a.devices.size(); i++) if (a.devices[(size_t)i].kind == DeviceInfo::File) file = i;
    if (file < 0) return false;
    if (a.engine.running()) a.engine.stop();
    a.file = FileOptions{};
    a.file.path = path;
    a.file.format = guessFormat(path);
    a.file.sampleRate = guessSampleRate(path) > 0 ? guessSampleRate(path) : rateHz;
    IqFileInfo info;
    std::string err;
    if (probeIqFile(path, info, err)) {
        a.file.path = info.dataPath;
        a.file.format = info.format;
        a.file.bigEndian = info.bigEndian;
        a.file.offsetBytes = info.offsetBytes;
        a.file.endBytes = info.endBytes;
        if (info.sampleRate > 0) a.file.sampleRate = info.sampleRate;
        restoreRecordingMode(a, info.description, path);   // before the centre: a change of mode resets the frequency
        const double centre = info.centerHz > 0 ? info.centerHz : filevfo::guessCentreHz(path);
        if (centre > 0) a.freqMhz = centre / 1e6;
    } else if (!err.empty()) {
        a.engine.log(err);
        return false;
    } else {
        restoreRecordingMode(a, "", path);
        if (const double centre = filevfo::guessCentreHz(path); centre > 0) a.freqMhz = centre / 1e6;
    }
    if (a.file.sampleRate <= 0) return false;
    a.devIdx = file;
    startReceiver(a);
    return a.engine.running();
}

bool onair_iq_record(bool on) {
    App& a = appRunApp();
    if (!on) { a.engine.stopRecording(); return true; }
    const FileFormat format = FileFormat::CI16;   // 16 bits: what a network radio delivers, with nothing to clip
    std::string err;
    if (a.engine.startRecording(folder() + "/" + a.engine.recordingName(format), format, err)) return true;
    a.engine.log(err);
    return false;
}

const char* onair_iq_record_json(void) {
    const RecordingStats s = appRunApp().engine.recordingStats();
    gRecord = std::string("{\"active\":") + (s.active ? "true" : "false") + ",\"seconds\":" + std::to_string(s.seconds) + ",\"bytes\":" + std::to_string(s.bytes) +
              ",\"dropped\":" + std::to_string(s.droppedSamples) + ",\"error\":\"" + jsonEscape(s.error) + "\"}";
    return gRecord.c_str();
}

}   // extern "C"
