// What a mode's exporter writes for the native screens: cards (label, value) and tables with the desktop's column names. The same JSON as android/native/src/results_json.cpp.
// Each results_<group>.cpp has one function that fills an Out for the standards it knows and returns false for the others.
#pragma once
#include <cstdio>
#include <initializer_list>
#include <cstdint>
#include <string>
#include <vector>
#include "dect2/net/remote_api.h"   // jsonEscape
#include "dect2/t2/t2rx.h"          // RxTelemetry

namespace onair::results {

inline std::string text(const char* format, double v) { char b[64]; std::snprintf(b, sizeof b, format, v); return b; }
inline std::string quoted(const std::string& s) { return "\"" + dect2::jsonEscape(s) + "\""; }

// Every table goes to the screens newest first. An exporter that walks its telemetry oldest first says so for the length of its work.
inline thread_local bool gRowsArriveOldestFirst = false;

class Table {
public:
    Table(const char* name, std::initializer_list<const char*> columns) : name_(name) {
        for (const char* c : columns) cols_ += (cols_.empty() ? "" : ",") + quoted(c);
    }
    void row(std::initializer_list<std::string> values) {
        std::string r;
        for (const std::string& v : values) r += (r.empty() ? "" : ",") + quoted(v);
        rows_ = oldestFirst() ? "[" + r + "]" + (rows_.empty() ? "" : "," + rows_) : rows_ + (rows_.empty() ? "[" : ",[") + r + "]";
        count_++;
    }
    int count() const { return count_; }
    std::string json() const { return "{\"name\":" + quoted(name_) + ",\"cols\":[" + cols_ + "],\"rows\":[" + rows_ + "]}"; }
private:
    static bool oldestFirst() { return gRowsArriveOldestFirst; }
    std::string name_, cols_, rows_;
    int count_ = 0;
};

class Out {
public:
    void card(const std::string& label, const std::string& value) { cards_ += (cards_.empty() ? "[" : ",[") + quoted(label) + "," + quoted(value) + "]"; }
    void table(const Table& t) { if (t.count() > 0) tables_ += (tables_.empty() ? "" : ",") + t.json(); }
    bool empty() const { return cards_.empty() && tables_.empty(); }
    std::string json() const { return "\"cards\":[" + cards_ + "],\"tables\":[" + tables_ + "]"; }
private:
    std::string cards_, tables_;
};

// false: this file does not know rx.standard
bool aviationMarine(const dect2::RxTelemetry& rx, Out& o);
bool satelliteScience(const dect2::RxTelemetry& rx, Out& o);
bool iotCellular(const dect2::RxTelemetry& rx, Out& o);
bool utilityTools(const dect2::RxTelemetry& rx, Out& o);
// the active mode's newest picture as RGBA; false when it has none
bool latestImage(const dect2::RxTelemetry& rx, std::vector<uint8_t>& rgba, int& w, int& h, uint64_t& seq);

} // namespace onair::results
