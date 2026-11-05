include_guard(GLOBAL)

# The runtime's other native libraries, pinned and built static once into
# TELAR_DEPENDENCIES_DIR: nghttp2, Brotli and zstd everywhere, and on Linux
# also zlib, SQLite and libpcap, which macOS takes from its SDK.
include("${CMAKE_CURRENT_LIST_DIR}/dependencies.cmake")

telar_managed_build(NAME "native libraries" RECIPE "${CMAKE_CURRENT_LIST_DIR}/native"
  ROOT "${TELAR_DEPENDENCIES_DIR}/native" TARGET telar-native JOBS "${TELAR_DEPENDENCIES_JOBS}"
  FILES CMakeLists.txt manifest.cmake sqlite.cmake RESULT TELAR_NATIVE_PREFIX)

set(TELAR_NATIVE_INCLUDE_DIR "${TELAR_NATIVE_PREFIX}/include")
set(NGHTTP2_LIBRARY "${TELAR_NATIVE_PREFIX}/lib/libnghttp2.a")
set(BROTLI_DECODER_LIBRARY "${TELAR_NATIVE_PREFIX}/lib/libbrotlidec.a")
set(BROTLI_ENCODER_LIBRARY "${TELAR_NATIVE_PREFIX}/lib/libbrotlienc.a")
set(BROTLI_COMMON_LIBRARY "${TELAR_NATIVE_PREFIX}/lib/libbrotlicommon.a")
set(ZSTD_LIBRARY "${TELAR_NATIVE_PREFIX}/lib/libzstd.a")
set(native_libraries NGHTTP2_LIBRARY BROTLI_DECODER_LIBRARY BROTLI_ENCODER_LIBRARY BROTLI_COMMON_LIBRARY ZSTD_LIBRARY)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  set(ZLIB_LIBRARY "${TELAR_NATIVE_PREFIX}/lib/libz.a")
  set(SQLITE3_LIBRARY "${TELAR_NATIVE_PREFIX}/lib/libsqlite3.a")
  set(PCAP_LIBRARY "${TELAR_NATIVE_PREFIX}/lib/libpcap.a")
  list(APPEND native_libraries ZLIB_LIBRARY SQLITE3_LIBRARY PCAP_LIBRARY)
endif()

foreach(library IN LISTS native_libraries)
  if(NOT EXISTS "${${library}}")
    message(FATAL_ERROR "The managed native build did not install ${${library}}")
  endif()
endforeach()
