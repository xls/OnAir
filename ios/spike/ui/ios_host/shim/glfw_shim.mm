// The GLFW stand-in of ios/shim/GLFW/glfw3.h, and the three ImGui_ImplGlfw_* calls main.cpp makes. The host sets the geometry
// with onair_shim_geometry() from the MTKView's layout; everything about windows, monitors and callbacks is a no-op.
#include <GLFW/glfw3.h>
#include "imgui.h"
#include <time.h>

namespace {
struct Win { int w = 390, h = 844, fbW = 1170, fbH = 2532; float scale = 3; bool close = false; } gW;
GLFWwindow* const kWin = reinterpret_cast<GLFWwindow*>(&gW);
GLFWmonitor* gMon = reinterpret_cast<GLFWmonitor*>(&gW);
GLFWvidmode gMode = {390, 844, 8, 8, 8, 60};
double now() { timespec t; clock_gettime(CLOCK_MONOTONIC_RAW, &t); return t.tv_sec + t.tv_nsec * 1e-9; }
const double gT0 = now();
double gLastNew = 0;
}

extern "C" void onair_shim_geometry(int w, int h, int fbW, int fbH, float scale) { gW.w = w; gW.h = h; gW.fbW = fbW; gW.fbH = fbH; gW.scale = scale; gMode.width = w; gMode.height = h; }

extern "C" {
int glfwInit(void) { return 1; }
void glfwTerminate(void) {}
void glfwInitHint(int, int) {}
GLFWerrorfun glfwSetErrorCallback(GLFWerrorfun) { return nullptr; }
double glfwGetTime(void) { return now() - gT0; }
void glfwPollEvents(void) {}
void glfwWaitEventsTimeout(double) {}   // never sleeps: the frame runs on the main thread, CADisplayLink paces it
void glfwDefaultWindowHints(void) {}
void glfwWindowHint(int, int) {}
GLFWwindow* glfwCreateWindow(int, int, const char*, GLFWmonitor*, GLFWwindow*) { return kWin; }   // a second one (the pop-out) is refused below
void glfwDestroyWindow(GLFWwindow*) {}
void glfwShowWindow(GLFWwindow*) {}
void glfwRestoreWindow(GLFWwindow*) {}
int glfwWindowShouldClose(GLFWwindow*) { return gW.close; }
void glfwSetWindowShouldClose(GLFWwindow*, int v) { gW.close = v != 0; }   // an app never quits itself: the host ignores it
int glfwGetWindowAttrib(GLFWwindow*, int a) {
    // Never "iconified", also in the background: minimisedFrame() (main.cpp:113) would then skip receiversFrame() and every tick with it.
    // The background goes through power::windowOccluded() instead: the UI keeps running at 10 Hz and only the GPU work is skipped.
    switch (a) { case GLFW_VISIBLE: case GLFW_FOCUSED: return 1; default: return 0; }
}
void glfwSetWindowAttrib(GLFWwindow*, int, int) {}
void glfwGetWindowSize(GLFWwindow*, int* x, int* y) { if (x) *x = gW.w; if (y) *y = gW.h; }
void glfwSetWindowSize(GLFWwindow*, int, int) {}
void glfwGetWindowPos(GLFWwindow*, int* x, int* y) { if (x) *x = 0; if (y) *y = 0; }
void glfwSetWindowPos(GLFWwindow*, int, int) {}
void glfwSetWindowSizeLimits(GLFWwindow*, int, int, int, int) {}
void glfwGetWindowFrameSize(GLFWwindow*, int* l, int* t, int* r, int* b) { if (l) *l = 0; if (t) *t = 0; if (r) *r = 0; if (b) *b = 0; }
void glfwGetFramebufferSize(GLFWwindow*, int* x, int* y) { if (x) *x = gW.fbW; if (y) *y = gW.fbH; }
void glfwGetWindowContentScale(GLFWwindow*, float* x, float* y) { if (x) *x = gW.scale; if (y) *y = gW.scale; }
GLFWmonitor* glfwGetWindowMonitor(GLFWwindow*) { return gMon; }   // always "full screen": the video-only view never asks to toggle it
void glfwSetWindowMonitor(GLFWwindow*, GLFWmonitor*, int, int, int, int, int) {}
GLFWmonitor* glfwGetPrimaryMonitor(void) { return gMon; }
GLFWmonitor** glfwGetMonitors(int* n) { if (n) *n = 1; return &gMon; }
void glfwGetMonitorPos(GLFWmonitor*, int* x, int* y) { if (x) *x = 0; if (y) *y = 0; }
void glfwGetMonitorWorkarea(GLFWmonitor*, int* x, int* y, int* w, int* h) { if (x) *x = 0; if (y) *y = 0; if (w) *w = gW.w; if (h) *h = gW.h; }
const GLFWvidmode* glfwGetVideoMode(GLFWmonitor*) { return &gMode; }
GLFWmonitorfun glfwSetMonitorCallback(GLFWmonitorfun) { return nullptr; }
GLFWwindowiconifyfun glfwSetWindowIconifyCallback(GLFWwindow*, GLFWwindowiconifyfun) { return nullptr; }
GLFWmousebuttonfun glfwSetMouseButtonCallback(GLFWwindow*, GLFWmousebuttonfun) { return nullptr; }
GLFWkeyfun glfwSetKeyCallback(GLFWwindow*, GLFWkeyfun) { return nullptr; }
GLFWdropfun glfwSetDropCallback(GLFWwindow*, GLFWdropfun) { return nullptr; }
GLFWwindow* glfwGetCurrentContext(void) { return nullptr; }   // diag_ui.cpp:129 skips its OpenGL strings
GLFWglproc glfwGetProcAddress(const char*) { return nullptr; }
}

// imgui_impl_glfw.h declares these; the real backend is not built on iOS. Input comes from ios/host (ImGuiIO events).
bool ImGui_ImplGlfw_InitForOther(GLFWwindow*, bool) {
    ImGuiIO& io = ImGui::GetIO();
    io.BackendPlatformName = "onair_ios";
    io.ConfigFlags |= ImGuiConfigFlags_IsTouchScreen;
    return true;
}
void ImGui_ImplGlfw_Shutdown() {}
void ImGui_ImplGlfw_NewFrame() {
    ImGuiIO& io = ImGui::GetIO();
    io.DisplaySize = ImVec2((float)gW.w, (float)gW.h);
    io.DisplayFramebufferScale = ImVec2(gW.scale, gW.scale);
    const double t = now();
    io.DeltaTime = gLastNew > 0 && t > gLastNew ? (float)(t - gLastNew) : 1.f / 60;
    gLastNew = t;
}
