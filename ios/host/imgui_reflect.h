// Reads a desktop panel as data: while a pass runs, the ImGui widgets draw nothing and instead report what they are (label, kind, value, range,
// choices), and a pending edit from a native control comes back to the panel as if the widget had been used. So every mode's settings reach the
// native drawers with no per-mode wiring, through the panel's own logic. imgui_widgets.cpp is compiled with its widgets renamed (ios/core/CMakeLists.txt).
#pragma once
#include <string>

namespace reflect {
void begin();                                       // the widgets report from here on
void section(const char* title);                    // the heading of what follows
void notes(bool on);                                // text counts too (a scan says what it is doing), under the heading "Scan"
std::string end();                                  // JSON: [{id, kind, label, section, value, min, max, options, disabled}]
void edit(unsigned id, const std::string& value);   // applied in the next pass
bool editPending();
}
