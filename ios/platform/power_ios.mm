// app/platform/power.h on iOS, in place of power.cpp and power_cocoa.mm (no IOKit power sources, no libproc). "Occluded" is how the host says the app is in the background: main.cpp
// then runs its existing path for a window nobody can see (UI at 10 Hz, skipFrame() instead of any GPU work).
#include "platform/power.h"
#import <UIKit/UIKit.h>
#include <atomic>

namespace power {

static std::atomic<bool> gOccluded{false};
void setHostOccluded(bool on) { gOccluded = on; }
bool windowOccluded(GLFWwindow*) { return gOccluded; }
bool onBattery() { return UIDevice.currentDevice.batteryState == UIDeviceBatteryStateUnplugged; }   // needs batteryMonitoringEnabled = YES at start
bool sampleUsage(Usage&) { return false; }   // the header allows it: "where it is not supported"
void setReceiving(bool) {}   // no App Nap here; the background audio mode is what keeps the process alive

}   // namespace power
