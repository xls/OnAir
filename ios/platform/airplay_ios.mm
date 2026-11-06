// Casting from the receiver is left out on iOS for now: the panels ask available() and hide it. In place of airplay_cocoa.mm.
#include "platform/airplay.h"

namespace airplay {
bool available() { return false; }
void choose(GLFWwindow*, float, float, float, float, const std::string&) {}
void stop() {}
State state() { return State::Idle; }
std::string message() { return std::string(); }
}
