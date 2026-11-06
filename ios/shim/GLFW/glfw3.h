// iOS stand-in for GLFW: just enough for app/ to compile unmodified. One "window" and one "monitor" exist (opaque tokens); the
// host (ios/) sets their size, scale and visibility. Input does not come through here: the host feeds ImGuiIO directly.
// Constants keep the real GLFW values.
#pragma once
#ifdef __cplusplus
extern "C" {
#endif

typedef struct GLFWwindow GLFWwindow;
typedef struct GLFWmonitor GLFWmonitor;
typedef struct GLFWvidmode { int width, height, redBits, greenBits, blueBits, refreshRate; } GLFWvidmode;
typedef void (*GLFWglproc)(void);
typedef void (*GLFWerrorfun)(int, const char*);
typedef void (*GLFWmonitorfun)(GLFWmonitor*, int);
typedef void (*GLFWwindowiconifyfun)(GLFWwindow*, int);
typedef void (*GLFWmousebuttonfun)(GLFWwindow*, int, int, int);
typedef void (*GLFWkeyfun)(GLFWwindow*, int, int, int, int);
typedef void (*GLFWdropfun)(GLFWwindow*, int, const char**);

#define GLFW_TRUE 1
#define GLFW_FALSE 0
#define GLFW_PRESS 1
#define GLFW_DONT_CARE (-1)
#define GLFW_MOUSE_BUTTON_LEFT 0
#define GLFW_KEY_ESCAPE 256
#define GLFW_KEY_F 70
#define GLFW_KEY_L 76
#define GLFW_KEY_S 83
#define GLFW_FOCUSED 0x00020001
#define GLFW_ICONIFIED 0x00020002
#define GLFW_RESIZABLE 0x00020003
#define GLFW_VISIBLE 0x00020004
#define GLFW_AUTO_ICONIFY 0x00020006
#define GLFW_FLOATING 0x00020007
#define GLFW_FOCUS_ON_SHOW 0x0002000C
#define GLFW_CLIENT_API 0x00022001
#define GLFW_NO_API 0

int glfwInit(void);
void glfwTerminate(void);
void glfwInitHint(int hint, int value);
GLFWerrorfun glfwSetErrorCallback(GLFWerrorfun cb);
double glfwGetTime(void);
void glfwPollEvents(void);
void glfwWaitEventsTimeout(double seconds);
void glfwDefaultWindowHints(void);
void glfwWindowHint(int hint, int value);
GLFWwindow* glfwCreateWindow(int w, int h, const char* title, GLFWmonitor* mon, GLFWwindow* share);
void glfwDestroyWindow(GLFWwindow* w);
void glfwShowWindow(GLFWwindow* w);
void glfwRestoreWindow(GLFWwindow* w);
int glfwWindowShouldClose(GLFWwindow* w);
void glfwSetWindowShouldClose(GLFWwindow* w, int v);
int glfwGetWindowAttrib(GLFWwindow* w, int attrib);
void glfwSetWindowAttrib(GLFWwindow* w, int attrib, int v);
void glfwGetWindowSize(GLFWwindow* w, int* x, int* y);
void glfwSetWindowSize(GLFWwindow* w, int x, int y);
void glfwGetWindowPos(GLFWwindow* w, int* x, int* y);
void glfwSetWindowPos(GLFWwindow* w, int x, int y);
void glfwSetWindowSizeLimits(GLFWwindow* w, int a, int b, int c, int d);
void glfwGetWindowFrameSize(GLFWwindow* w, int* l, int* t, int* r, int* b);
void glfwGetFramebufferSize(GLFWwindow* w, int* x, int* y);
void glfwGetWindowContentScale(GLFWwindow* w, float* x, float* y);
GLFWmonitor* glfwGetWindowMonitor(GLFWwindow* w);
void glfwSetWindowMonitor(GLFWwindow* w, GLFWmonitor* m, int x, int y, int ww, int hh, int rate);
GLFWmonitor* glfwGetPrimaryMonitor(void);
GLFWmonitor** glfwGetMonitors(int* count);
void glfwGetMonitorPos(GLFWmonitor* m, int* x, int* y);
void glfwGetMonitorWorkarea(GLFWmonitor* m, int* x, int* y, int* w, int* h);
const GLFWvidmode* glfwGetVideoMode(GLFWmonitor* m);
GLFWmonitorfun glfwSetMonitorCallback(GLFWmonitorfun cb);
GLFWwindowiconifyfun glfwSetWindowIconifyCallback(GLFWwindow* w, GLFWwindowiconifyfun cb);
GLFWmousebuttonfun glfwSetMouseButtonCallback(GLFWwindow* w, GLFWmousebuttonfun cb);
GLFWkeyfun glfwSetKeyCallback(GLFWwindow* w, GLFWkeyfun cb);
GLFWdropfun glfwSetDropCallback(GLFWwindow* w, GLFWdropfun cb);
GLFWwindow* glfwGetCurrentContext(void);
GLFWglproc glfwGetProcAddress(const char* name);

#ifdef __cplusplus
}
#endif
