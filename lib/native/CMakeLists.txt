cmake_minimum_required(VERSION 4.4.5)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_native LANGUAGES C CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/cpp_modules.cmake")

# The headers of the runtime's pinned native libraries: nghttp2, Brotli and zstd from the managed
# build, and zlib, SQLite and libpcap from it on Linux and from the SDK on macOS. Each process that
# calls into a library links it itself.
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/deps/native.cmake")

add_library(telar-native STATIC zlib/zlib.cpp)
add_library(telar::native ALIAS telar-native)
telar_modules(telar-native)
target_include_directories(telar-native SYSTEM PUBLIC "${TELAR_NATIVE_INCLUDE_DIR}")

telar_editor_flags(telar-native)
