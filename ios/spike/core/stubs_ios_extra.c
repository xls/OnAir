/* The symbols the iOS link needs beyond android/native/src/stubs_ext.c */
#include <stddef.h>
void* av_buffer_ref(void) { return NULL; }
long av_hwdevice_ctx_create(void) { return -1; }
long av_hwframe_transfer_data(void) { return -1; }
long libusb_bulk_transfer(void) { return -1; }
long libusb_get_configuration(void) { return -1; }
long libusb_get_port_numbers(void) { return -1; }
long libusb_set_configuration(void) { return -1; }
