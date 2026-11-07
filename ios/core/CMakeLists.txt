# libonair_ios: the receiver library (dect2core and Rust, from this repository) the C++ interface (app/) and the C interface the Swift app calls.
# All C, C++ and Rust is built here; Xcode builds only the Swift. Run through ios/tools/build_core.sh.
cmake_minimum_required(VERSION 3.22)
project(onair_ios LANGUAGES C CXX OBJCXX)

get_filename_component(_onair_repo "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)

set(DECT2_BUILD_APP ON CACHE BOOL "" FORCE)   # app/ becomes the static library dect2, not a program
set(DECT2_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(DECT2_WITH_SOAPY OFF CACHE BOOL "" FORCE)
set(DECT2_HAVE_HAMLIB OFF CACHE BOOL "" FORCE)
set(DECT2_BUNDLE_CODEC2 ON CACHE BOOL "" FORCE)    # libcodec2 goes into the app as a signed library

add_subdirectory("${_onair_repo}" "${CMAKE_BINARY_DIR}/onair-core" EXCLUDE_FROM_ALL)

set(ONAIR_IIO_SYMBOLS "" CACHE FILEPATH "Generated table of libiio functions (build_core.sh)")
# results_json.cpp turns telemetry into cards and tables. It has no Android code in it, so it is shared rather than copied
target_sources(dect2 PRIVATE "${_onair_repo}/android/native/src/results_json.cpp" ../host/onair_host.mm ../host/results_aviation.cpp ../host/results_satellite.cpp ../host/results_iot.cpp ../host/results_utility.cpp ../host/iptv_host.cpp ../host/iq_host.cpp ../host/shortwave_host.cpp ../shim/glfw_shim.mm ../platform/power_ios.mm ../platform/airplay_ios.mm)
target_include_directories(dect2 PRIVATE include ../host "${_onair_repo}/android/native/src")

add_library(onair_ios STATIC src/stubs_ext.c "${ONAIR_IIO_SYMBOLS}")
target_link_libraries(onair_ios PRIVATE dect2)
