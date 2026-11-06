# libonair_ios: the receiver library (dect2core and Rust, from this repository) plus the C interface the Swift app calls.
# All C, C++ and Rust is built here; Xcode builds only the Swift. Run through ios/tools/build_core.sh.
cmake_minimum_required(VERSION 3.22)
project(onair_ios LANGUAGES C CXX OBJCXX)

get_filename_component(_onair_repo "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)

set(DECT2_BUILD_APP OFF CACHE BOOL "" FORCE)
set(DECT2_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(DECT2_WITH_SOAPY OFF CACHE BOOL "" FORCE)
set(DECT2_HAVE_HAMLIB OFF CACHE BOOL "" FORCE)
set(DECT2_BUNDLE_CODEC2 OFF CACHE BOOL "" FORCE)

add_subdirectory("${_onair_repo}" "${CMAKE_BINARY_DIR}/onair-core" EXCLUDE_FROM_ALL)

set(ONAIR_IIO_SYMBOLS "" CACHE FILEPATH "Generated table of libiio functions (build_core.sh)")
add_library(onair_ios STATIC src/onair_core.mm src/stubs_ext.c "${ONAIR_IIO_SYMBOLS}")
set_target_properties(onair_ios PROPERTIES CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON OBJCXX_STANDARD 20)
target_include_directories(onair_ios PRIVATE "${_onair_repo}/core/include" include src)
target_compile_options(onair_ios PRIVATE -O2 -Wall)
target_link_libraries(onair_ios PRIVATE dect2core)
