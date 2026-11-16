# The headers of the runtime's pinned native libraries: nghttp2, Brotli and zstd from the managed
# build, and zlib, SQLite and libpcap from it on Linux and from the SDK on macOS. Each process that
# calls into a library links it itself.
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/deps/native.cmake")

telar_add_library(telar-native SOURCES zlib/zlib.cpp)
target_include_directories(telar-native SYSTEM PUBLIC "${TELAR_NATIVE_INCLUDE_DIR}")
