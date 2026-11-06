/* Stand-ins for the libusb and libhackrf entry points the core links to. iOS has no USB radios, so every call fails cleanly with NULL or -1. The scan calls instead succeed and find nothing, which is the truth here: no USB radios. */
#include <stddef.h>
#include <stdint.h>
#define KEEP __attribute__((visibility("default"), used))
KEEP long hackrf_board_id_read(void) { return -1; }
KEEP long hackrf_close(void) { return -1; }
KEEP const char* hackrf_board_id_name(void) { return "unavailable"; }
KEEP void* hackrf_device_list(void) { return 0; }
KEEP void hackrf_device_list_free(void) { }
KEEP const char* hackrf_error_name(void) { return "unavailable"; }
KEEP const char* hackrf_usb_board_id_name(void) { return "unavailable"; }
KEEP long hackrf_exit(void) { return 0; }
KEEP long hackrf_init(void) { return 0; }
KEEP long hackrf_init_sweep(void) { return -1; }
KEEP long hackrf_open(void) { return -1; }
KEEP long hackrf_open_by_serial(void) { return -1; }
KEEP long hackrf_set_amp_enable(void) { return -1; }
KEEP long hackrf_set_antenna_enable(void) { return -1; }
KEEP long hackrf_set_baseband_filter_bandwidth(void) { return -1; }
KEEP long hackrf_set_freq(void) { return -1; }
KEEP long hackrf_set_lna_gain(void) { return -1; }
KEEP long hackrf_set_sample_rate(void) { return -1; }
KEEP long hackrf_set_vga_gain(void) { return -1; }
KEEP long hackrf_start_rx(void) { return -1; }
KEEP long hackrf_start_rx_sweep(void) { return -1; }
KEEP long hackrf_stop_rx(void) { return -1; }
KEEP long libusb_set_option(void) { return -1; }
KEEP long libusb_wrap_sys_device(void) { return -12; }   /* LIBUSB_ERROR_NOT_SUPPORTED */
KEEP void* libusb_alloc_transfer(void) { return NULL; }
KEEP long libusb_cancel_transfer(void) { return -1; }
KEEP long libusb_claim_interface(void) { return -1; }
KEEP long libusb_close(void) { return -1; }
KEEP long libusb_control_transfer(void) { return -1; }
KEEP long libusb_detach_kernel_driver(void) { return -1; }
KEEP const char* libusb_error_name(void) { return "unavailable"; }
KEEP long libusb_exit(void) { return -1; }
KEEP long libusb_free_config_descriptor(void) { return -1; }
KEEP long libusb_free_device_list(void) { return -1; }
KEEP long libusb_free_transfer(void) { return -1; }
KEEP long libusb_get_active_config_descriptor(void) { return -1; }
KEEP long libusb_get_bus_number(void) { return -1; }
KEEP long libusb_get_device_address(void) { return -1; }
KEEP long libusb_get_device_descriptor(void) { return -1; }
KEEP long libusb_get_device_list(void* ctx, void*** list) { static void* none[1] = {NULL}; (void)ctx; if (list) *list = none; return 0; }
KEEP long libusb_get_device_speed(void) { return -1; }
KEEP long libusb_get_string_descriptor_ascii(void) { return -1; }
KEEP long libusb_handle_events_timeout_completed(void) { return -1; }
KEEP long libusb_init(void** ctx) { static int none; if (ctx) *ctx = &none; return 0; }
KEEP long libusb_interrupt_event_handler(void) { return -1; }
KEEP long libusb_kernel_driver_active(void) { return -1; }
KEEP long libusb_open(void) { return -1; }
KEEP long libusb_release_interface(void) { return -1; }
KEEP long libusb_submit_transfer(void) { return -1; }
KEEP long libusb_bulk_transfer(void) { return -1; }
KEEP long libusb_get_configuration(void) { return -1; }
KEEP long libusb_get_port_numbers(void) { return -1; }
KEEP long libusb_set_configuration(void) { return -1; }
