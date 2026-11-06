// The C interface between the Swift app and the receiver. Plain C so that Swift can import it.
#pragma once
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif

// Once at launch. dataDir: a writable folder for results.
void onair_core_init(const char* dataDir);
// Starts the built-in FM test signal: 1 kHz left, 3 kHz right. Returns false and fills err on failure.
bool onair_core_start_fm_test(char* err, int errSize);
void onair_core_stop(void);
bool onair_core_running(void);
void onair_core_set_volume(float volume01);
// One line of the receiver's state, for the screen and the log.
void onair_core_status(char* out, int outSize);

#ifdef __cplusplus
}
#endif
