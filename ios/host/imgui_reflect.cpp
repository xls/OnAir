#include "imgui_reflect.h"
#include "dect2/net/remote_api.h"
#include "imgui.h"
#include "imgui_internal.h"
#include <algorithm>
#include <cctype>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <string>
#include <vector>

// the real widgets, renamed where they are compiled
namespace ImGui {
bool Orig_Checkbox(const char*, bool*);
bool Orig_BeginCombo(const char*, const char*, ImGuiComboFlags);
void Orig_EndCombo();
bool Orig_Combo(const char*, int*, const char* const[], int, int);
bool Orig_Combo(const char*, int*, const char*, int);
bool Orig_Combo(const char*, int*, const char* (*)(void*, int), void*, int, int);
bool Orig_Selectable(const char*, bool, ImGuiSelectableFlags, const ImVec2&);
bool Orig_Selectable(const char*, bool*, ImGuiSelectableFlags, const ImVec2&);
bool Orig_SliderFloat(const char*, float*, float, float, const char*, ImGuiSliderFlags);
bool Orig_SliderInt(const char*, int*, int, int, const char*, ImGuiSliderFlags);
bool Orig_InputDouble(const char*, double*, double, double, const char*, ImGuiInputTextFlags);
bool Orig_InputFloat(const char*, float*, float, float, const char*, ImGuiInputTextFlags);
bool Orig_InputInt(const char*, int*, int, int, ImGuiInputTextFlags);
bool Orig_InputText(const char*, char*, size_t, ImGuiInputTextFlags, ImGuiInputTextCallback, void*);
bool Orig_InputTextWithHint(const char*, const char*, char*, size_t, ImGuiInputTextFlags, ImGuiInputTextCallback, void*);
bool Orig_RadioButton(const char*, bool);
bool Orig_RadioButton(const char*, int*, int);
bool Orig_Button(const char*, const ImVec2&);
bool Orig_SmallButton(const char*);
bool Orig_CollapsingHeader(const char*, ImGuiTreeNodeFlags);
bool Orig_CollapsingHeader(const char*, bool*, ImGuiTreeNodeFlags);
void Orig_TextUnformatted(const char*, const char*);
void Orig_PushID(const char*);
void Orig_PushID(const char*, const char*);
void Orig_PushID(const void*);
void Orig_PushID(int);
bool Orig_InvisibleButton(const char*, const ImVec2&, ImGuiButtonFlags);
bool Orig_BeginTabBar(const char*, ImGuiTabBarFlags);
void Orig_EndTabBar();
bool Orig_BeginTabItem(const char*, bool*, ImGuiTabItemFlags);
void Orig_EndTabItem();
bool Orig_IsItemHovered(ImGuiHoveredFlags);
bool Orig_BeginTooltip();
void Orig_EndTooltip();
void Orig_SetTooltipV(const char*, va_list);
bool Orig_BeginItemTooltip();
void Orig_SetItemTooltipV(const char*, va_list);
}

namespace {
struct Item {
    unsigned id = 0;
    std::string kind, label, section, value, help, preview;
    bool guessed = false;   // the label is only the text that stood before it
    double lo = 0, hi = 0;
    std::vector<std::string> options;
    bool disabled = false;
};

bool gOn = false, gHasEdit = false;
unsigned gEditId = 0;
std::string gEditValue, gSection, gLastText;
std::vector<Item> gItems;
std::set<unsigned> gSeen;
int gCombo = -1;   // an index: a panel may add more items inside an open combo, which moves the list
int gOption = 0;
bool gInTooltip = false;
bool gNotes = false;
std::string gPushed;   // the text of the last PushID: icon buttons keep their name there

std::string visible(const char* label) {   // the part of a label ImGui shows
    std::string s = label ? label : "";
    const size_t cut = s.find("##");
    if (cut != std::string::npos) s.resize(cut);
    while (!s.empty() && (s.back() == ' ' || s.back() == ':')) s.pop_back();
    return s;
}

Item* add(const char* kind, const char* label) {
    const unsigned id = ImGui::GetID(label);
    if (!gSeen.insert(id).second) return nullptr;
    Item it;
    it.id = id;
    it.kind = kind;
    it.label = visible(label);
    if (it.label.empty()) { it.label = gLastText; it.guessed = true; }
    it.section = gNotes && gSection != "Scan" ? "Scan: " + gSection : gSection;
    it.disabled = (GImGui->CurrentItemFlags & ImGuiItemFlags_Disabled) != 0;
    gItems.push_back(std::move(it));
    gLastText.clear();
    return &gItems.back();
}

bool edited(const char* label) { return gHasEdit && ImGui::GetID(label) == gEditId; }
std::string num(double v) { char b[40]; snprintf(b, sizeof b, "%.10g", v); return b; }

template <class T> bool number(const char* kind, const char* label, T* v, double lo, double hi) {
    const bool hit = edited(label);
    if (hit) *v = (T)atof(gEditValue.c_str());
    if (Item* it = add(kind, label)) { it->value = num((double)*v); it->lo = lo; it->hi = hi; }
    return hit;
}

bool textField(const char* label, char* buf, size_t size) {
    const bool hit = edited(label);
    if (hit) snprintf(buf, size, "%s", gEditValue.c_str());
    if (Item* it = add("text", label)) it->value = buf;
    return hit;
}

bool choice(const char* label, int* current, int count, const std::vector<std::string>& names) {
    const bool hit = edited(label);
    if (hit) *current = atoi(gEditValue.c_str());
    if (Item* it = add("choice", label)) { it->value = std::to_string(*current); it->options = names; }
    (void)count;
    return hit;
}
}   // namespace

static int gNoteCount = 0;

static std::string lower(std::string s) { for (char& c : s) c = (char)tolower((unsigned char)c); return s; }

// Something that opens a desktop window, panel, dialog or folder does nothing on the phone, so it is never offered
static bool desktopOnly(const std::string& text) {
    const std::string t = lower(text);
    for (const char* word : {"...", "\xE2\x80\xA6", "panel", "window", "folder", "dialog", "browse", "open ", "copy", "export", "import", "save results", "shared data", "scanner", "second mode"})
        if (t.find(word) != std::string::npos) return true;
    return false;
}

// A button is shown only when it is an action known to work here. Everything else (band shortcuts the native pages have, file and view buttons) stays off
static bool workingButton(const std::string& label) {
    const std::string t = lower(label);
    if (desktopOnly(t) || t == "scan") return false;   // "Scan" alone switches the desktop's view
    for (const char* word : {"scan ", "stop", "start", "clear", "reset", "skip", "record"}) if (t.rfind(word, 0) == 0) return true;
    return false;
}
// Text that names nothing: a dash, a stray unit or letter, a value that happened to stand beside the control
static bool meaningless(const std::string& label) {
    size_t letters = 0;
    for (char c : label) if (isalpha((unsigned char)c)) letters++;
    if (letters < 2) return true;
    const std::string t = lower(label);
    for (const char* unit : {"hz", "khz", "mhz", "ghz", "db", "ms", "to", "ppm", "bd", "hop"}) if (t == unit) return true;
    return false;
}

static std::string readable(const std::string& label) {
    if (label == "RATE") return "Sample rate";
    if (label == "BW") return "Bandwidth";
    return label;
}

static std::string shortHelp(const std::string& help) {   // a name for a control that has only a tooltip
    size_t cut = help.find_first_of(".:,(;\n");
    if (cut == std::string::npos || cut > 40) cut = std::min<size_t>(help.size(), 40);
    return help.substr(0, cut);
}

namespace reflect {
void begin() { gOn = true; gItems.clear(); gSeen.clear(); gSection.clear(); gLastText.clear(); gCombo = -1; }
void section(const char* title) { gSection = title; }
void notes(bool on) { gNotes = on; if (on) { gSection = "Scan"; gNoteCount = 0; } }
void edit(unsigned id, const std::string& value) { gEditId = id; gEditValue = value; gHasEdit = true; }
bool editPending() { return gHasEdit; }

std::string end() {
    gOn = false;
    gHasEdit = false;
    std::string j = "[";
    std::string before;   // the control just above: a nameless setting beside a switch belongs to it
    for (Item& it : gItems) {
        const bool readout = it.guessed && it.label.find_first_of("0123456789") != std::string::npos;
        if ((it.label.empty() || readout || meaningless(it.label)) && it.kind != "note") it.label = it.help.empty() ? std::string() : shortHelp(it.help);
        if (it.label.empty() && it.kind != "note" && it.kind != "button" && !before.empty()) it.label = before + " setting";
        if (it.kind != "note" && it.kind != "button" && it.label.find(" setting") == std::string::npos) before = it.label;
        it.label = readable(it.label);
        if (it.kind == "button" && !workingButton(it.label)) continue;
        if (it.kind != "note" && desktopOnly(it.label)) continue;
        if (lower(it.label) == "compute") continue;   // where the error correction runs: stays on Auto, there is nothing on the phone to see from it
        if (j.size() > 1) j += ",";
        j += "{\"id\":" + std::to_string(it.id) + ",\"kind\":\"" + it.kind + "\",\"label\":\"" + dect2::jsonEscape(it.label) + "\",\"section\":\"" + dect2::jsonEscape(it.section) +
             "\",\"help\":\"" + dect2::jsonEscape(it.help) + "\",\"preview\":\"" + dect2::jsonEscape(it.preview) + "\",\"value\":\"" + dect2::jsonEscape(it.value) + "\",\"lo\":" + num(it.lo) + ",\"hi\":" + num(it.hi) + ",\"disabled\":" + (it.disabled ? "true" : "false") + ",\"options\":[";
        for (size_t i = 0; i < it.options.size(); i++) j += std::string(i ? "," : "") + "\"" + dect2::jsonEscape(it.options[i]) + "\"";
        j += "]}";
    }
    return j + "]";
}
}   // namespace reflect

namespace ImGui {
bool Checkbox(const char* label, bool* v) {
    if (!gOn) return Orig_Checkbox(label, v);
    const bool hit = edited(label);
    if (hit) *v = gEditValue == "1";
    if (Item* it = add("toggle", label)) it->value = *v ? "1" : "0";
    return hit;
}

bool BeginCombo(const char* label, const char* preview, ImGuiComboFlags flags) {
    if (!gOn) return Orig_BeginCombo(label, preview, flags);
    Item* item = add("choice", label);
    if (!item) return false;
    item->value = "-1";
    item->preview = visible(preview);
    gCombo = (int)gItems.size() - 1;
    gOption = 0;
    PushID(label);   // what the panel's Selectable lines and PushIDs see stays the same at every pass
    return true;
}

void EndCombo() {
    if (!gOn) { Orig_EndCombo(); return; }
    PopID();
    gCombo = -1;
}

bool Combo(const char* label, int* current, const char* const items[], int count, int popup) {
    if (!gOn) return Orig_Combo(label, current, items, count, popup);
    std::vector<std::string> names;
    for (int i = 0; i < count; i++) names.push_back(items[i] ? visible(items[i]) : "");
    return choice(label, current, count, names);
}

bool Combo(const char* label, int* current, const char* zeroSeparated, int popup) {
    if (!gOn) return Orig_Combo(label, current, zeroSeparated, popup);
    std::vector<std::string> names;
    for (const char* p = zeroSeparated; *p; p += strlen(p) + 1) names.push_back(p);
    return choice(label, current, (int)names.size(), names);
}

bool Combo(const char* label, int* current, const char* (*getter)(void*, int), void* data, int count, int popup) {
    if (!gOn) return Orig_Combo(label, current, getter, data, count, popup);
    std::vector<std::string> names;
    for (int i = 0; i < count; i++) { const char* n = getter(data, i); names.push_back(n ? n : ""); }
    return choice(label, current, count, names);
}

static bool option(const char* label, bool selected) {
    if (gCombo < 0) return false;
    Item& combo = gItems[(size_t)gCombo];
    const int index = gOption++;
    combo.options.push_back(desktopOnly(label) ? std::string() : visible(label));   // blank keeps the numbering of the rest
    if (selected) combo.value = std::to_string(index);
    return gHasEdit && combo.id == gEditId && atoi(gEditValue.c_str()) == index;
}

bool Selectable(const char* label, bool selected, ImGuiSelectableFlags flags, const ImVec2& size) {
    return gOn ? option(label, selected) : Orig_Selectable(label, selected, flags, size);
}

bool Selectable(const char* label, bool* selected, ImGuiSelectableFlags flags, const ImVec2& size) {
    if (!gOn) return Orig_Selectable(label, selected, flags, size);
    const bool hit = option(label, selected && *selected);
    if (hit && selected) *selected = true;
    return hit;
}

bool SliderFloat(const char* label, float* v, float lo, float hi, const char* format, ImGuiSliderFlags flags) {
    return gOn ? number("slider", label, v, lo, hi) : Orig_SliderFloat(label, v, lo, hi, format, flags);
}
bool SliderInt(const char* label, int* v, int lo, int hi, const char* format, ImGuiSliderFlags flags) {
    return gOn ? number("slider", label, v, lo, hi) : Orig_SliderInt(label, v, lo, hi, format, flags);
}
bool InputDouble(const char* label, double* v, double step, double fast, const char* format, ImGuiInputTextFlags flags) {
    return gOn ? number("number", label, v, 0, 0) : Orig_InputDouble(label, v, step, fast, format, flags);
}
bool InputFloat(const char* label, float* v, float step, float fast, const char* format, ImGuiInputTextFlags flags) {
    return gOn ? number("number", label, v, 0, 0) : Orig_InputFloat(label, v, step, fast, format, flags);
}
bool InputInt(const char* label, int* v, int step, int fast, ImGuiInputTextFlags flags) {
    return gOn ? number("number", label, v, 0, 0) : Orig_InputInt(label, v, step, fast, flags);
}
bool InputText(const char* label, char* buf, size_t size, ImGuiInputTextFlags flags, ImGuiInputTextCallback cb, void* user) {
    return gOn ? textField(label, buf, size) : Orig_InputText(label, buf, size, flags, cb, user);
}
bool InputTextWithHint(const char* label, const char* hint, char* buf, size_t size, ImGuiInputTextFlags flags, ImGuiInputTextCallback cb, void* user) {
    return gOn ? textField(label, buf, size) : Orig_InputTextWithHint(label, hint, buf, size, flags, cb, user);
}

bool RadioButton(const char* label, bool active) {
    if (!gOn) return Orig_RadioButton(label, active);
    const bool hit = edited(label);
    if (Item* it = add("radio", label)) it->value = active ? "1" : "0";
    return hit;
}
bool RadioButton(const char* label, int* v, int button) {
    if (!gOn) return Orig_RadioButton(label, v, button);
    const bool hit = edited(label);
    if (hit) *v = button;
    if (Item* it = add("radio", label)) it->value = *v == button ? "1" : "0";
    return hit;
}

bool Button(const char* label, const ImVec2& size) {
    if (!gOn) return Orig_Button(label, size);
    const bool hit = edited(label);
    add("button", label);
    return hit;
}
bool SmallButton(const char* label) {
    if (!gOn) return Orig_SmallButton(label);
    const bool hit = edited(label);
    add("button", label);
    return hit;
}

bool CollapsingHeader(const char* label, ImGuiTreeNodeFlags flags) {
    if (!gOn) return Orig_CollapsingHeader(label, flags);
    gSection = visible(label);
    return true;
}
bool CollapsingHeader(const char* label, bool* visibleFlag, ImGuiTreeNodeFlags flags) {
    if (!gOn) return Orig_CollapsingHeader(label, visibleFlag, flags);
    gSection = visible(label);
    return true;
}

// what stands beside a control with no label of its own
static void remember(const char* text, const char* end = nullptr) {
    if (!gOn) return;
    const std::string t = end ? std::string(text, end) : std::string(text);
    if (gInTooltip) {
        if (!gItems.empty() && gItems.back().help.size() < 240) gItems.back().help += (gItems.back().help.empty() ? "" : " ") + t;
        return;
    }
    if (!gItems.empty() && gItems.back().label.empty() && gItems.back().kind == "toggle") gItems.back().label = t.substr(0, 40);   // a list row: its name comes after the box
    if (gNotes && gCombo < 0 && !t.empty() && gNoteCount < 8) {
        gNoteCount++;
        Item note;
        note.id = ImHashStr(t.c_str());
        note.kind = "note";
        note.label = t;
        note.section = gSection == "Scan" ? gSection : "Scan: " + gSection;
        if (gSeen.insert(note.id).second) gItems.push_back(std::move(note));
        return;
    }
    gLastText = t.substr(0, 60);
}

static void tooltip(const char* fmt, va_list args) {
    char b[300];
    vsnprintf(b, sizeof b, fmt, args);
    const bool was = gInTooltip;
    gInTooltip = true;
    remember(b);
    gInTooltip = was;
}

bool IsItemHovered(ImGuiHoveredFlags flags) { return gOn ? true : Orig_IsItemHovered(flags); }   // so the panel says what the control is for
bool BeginTooltip() { if (!gOn) return Orig_BeginTooltip(); gInTooltip = true; return true; }
void EndTooltip() { if (!gOn) { Orig_EndTooltip(); return; } gInTooltip = false; }
bool BeginItemTooltip() { if (!gOn) return Orig_BeginItemTooltip(); gInTooltip = true; return true; }
void SetTooltipV(const char* fmt, va_list args) { if (gOn) tooltip(fmt, args); else Orig_SetTooltipV(fmt, args); }
void SetItemTooltipV(const char* fmt, va_list args) { if (gOn) tooltip(fmt, args); else Orig_SetItemTooltipV(fmt, args); }
void SetTooltip(const char* fmt, ...) { va_list args; va_start(args, fmt); SetTooltipV(fmt, args); va_end(args); }
void SetItemTooltip(const char* fmt, ...) { va_list args; va_start(args, fmt); SetItemTooltipV(fmt, args); va_end(args); }

void PushID(const char* id) { if (gOn) gPushed = id; Orig_PushID(id); }
void PushID(const char* begin, const char* end) { Orig_PushID(begin, end); }
void PushID(const void* id) { Orig_PushID(id); }
void PushID(int id) { Orig_PushID(id); }

bool InvisibleButton(const char* id, const ImVec2& size, ImGuiButtonFlags flags) {
    if (!gOn) return Orig_InvisibleButton(id, size, flags);
    const bool hit = edited(id);
    if (!gPushed.empty()) {   // an icon button with words on it; the bare ones are plots and sliders of their own
        if (Item* it = add("button", id)) { it->label = visible(gPushed.c_str()); it->guessed = false; }
        gPushed.clear();
    }
    return hit;
}

bool BeginTabBar(const char* id, ImGuiTabBarFlags flags) { return gOn ? true : Orig_BeginTabBar(id, flags); }
void EndTabBar() { if (!gOn) Orig_EndTabBar(); }
bool BeginTabItem(const char* label, bool* open, ImGuiTabItemFlags flags) {
    if (!gOn) return Orig_BeginTabItem(label, open, flags);
    gSection = visible(label);
    PushID(label);
    return true;
}
void EndTabItem() { if (gOn) PopID(); else Orig_EndTabItem(); }

void TextUnformatted(const char* text, const char* end) { remember(text, end); Orig_TextUnformatted(text, end); }
void Text(const char* fmt, ...) {
    va_list args; va_start(args, fmt); char b[256]; vsnprintf(b, sizeof b, fmt, args); va_end(args);
    remember(b); Orig_TextUnformatted(b, nullptr);
}
void TextDisabled(const char* fmt, ...) {
    va_list args; va_start(args, fmt); char b[256]; vsnprintf(b, sizeof b, fmt, args); va_end(args);
    remember(b);
    va_start(args, fmt); TextDisabledV(fmt, args); va_end(args);
}
void TextColored(const ImVec4& col, const char* fmt, ...) {
    va_list args; va_start(args, fmt); char b[256]; vsnprintf(b, sizeof b, fmt, args); va_end(args);
    remember(b);
    va_start(args, fmt); TextColoredV(col, fmt, args); va_end(args);
}
void TextWrapped(const char* fmt, ...) {
    va_list args; va_start(args, fmt); char b[256]; vsnprintf(b, sizeof b, fmt, args); va_end(args);
    remember(b);
    va_start(args, fmt); TextWrappedV(fmt, args); va_end(args);
}
}   // namespace ImGui
