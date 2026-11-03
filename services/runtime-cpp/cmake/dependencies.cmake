set(GHOSTTY_VT_ROOT "" CACHE PATH "Installed libghostty-vt prefix")
if((GHOSTTY_VT_ROOT AND NOT "${GHOSTTY_VT_ROOT}" STREQUAL "${TELAR_LAST_GHOSTTY_VT_ROOT}") OR NOT "${TELAR_LAST_GHOSTTY_STATE_VERSION}" STREQUAL "${TELAR_GHOSTTY_STATE_VERSION}")
  unset(GHOSTTY_VT_INCLUDE_DIR CACHE)
  unset(GHOSTTY_VT_LIBRARY CACHE)
  unset(GHOSTTY_VT_HAS_RUNTIME_STORAGE_STATE CACHE)
  unset(GHOSTTY_VT_HAS_WUFFS_PNG CACHE)
endif()
set(TELAR_LAST_GHOSTTY_VT_ROOT "${GHOSTTY_VT_ROOT}" CACHE INTERNAL "Prefix used for the VT state ABI checks" FORCE)
set(TELAR_LAST_GHOSTTY_STATE_VERSION "${TELAR_GHOSTTY_STATE_VERSION}" CACHE INTERNAL "State ABI used for the VT feature checks" FORCE)
find_path(GHOSTTY_VT_INCLUDE_DIR ghostty/vt.h HINTS "${GHOSTTY_VT_ROOT}/include" REQUIRED)
find_library(GHOSTTY_VT_LIBRARY NAMES libghostty-vt.a HINTS "${GHOSTTY_VT_ROOT}/lib" REQUIRED)
file(READ "${CMAKE_CURRENT_LIST_DIR}/../vendor/wuffs-codec.json" TELAR_WUFFS_METADATA)
string(JSON TELAR_WUFFS_HEADER_SHA256 GET "${TELAR_WUFFS_METADATA}" header_sha256)
set(TELAR_WUFFS_HEADER "${GHOSTTY_VT_INCLUDE_DIR}/ghostty/wuffs-v0.4.h")
if(NOT EXISTS "${TELAR_WUFFS_HEADER}")
  message(FATAL_ERROR "Build the pinned VT dependency with tools/build_ghostty.py to prepare its generic PNG header")
endif()
file(SHA256 "${TELAR_WUFFS_HEADER}" TELAR_WUFFS_ACTUAL_SHA256)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_LIST_DIR}/../vendor/wuffs-codec.json" "${TELAR_WUFFS_HEADER}")
if(NOT TELAR_WUFFS_ACTUAL_SHA256 STREQUAL TELAR_WUFFS_HEADER_SHA256)
  message(FATAL_ERROR "The generic PNG header does not match the pinned VT codec")
endif()

find_package(Python3 REQUIRED COMPONENTS Interpreter)
find_package(Threads REQUIRED)

option(TELAR_RUNTIME_DISTRIBUTABLE "Require static non-system dependencies for installation" OFF)
# Linux has no base system: a distributable build is a static musl
# executable, so it starts on any distribution, Alpine included, with every
# library linked in. glibc cannot link statically everything it needs, so
# the build must run on musl (Alpine).
set(TELAR_LINUX_DISTRIBUTABLE OFF)
if(TELAR_RUNTIME_DISTRIBUTABLE AND CMAKE_SYSTEM_NAME STREQUAL "Linux")
  set(TELAR_LINUX_DISTRIBUTABLE ON)
  include(CheckCXXSourceCompiles)
  check_cxx_source_compiles("#include <cstdio>
#if defined(__GLIBC__)
#error glibc
#endif
int main() {}" TELAR_MUSL)
  if(NOT TELAR_MUSL)
    message(FATAL_ERROR "The Linux distributable build links statically against musl; build it on Alpine")
  endif()
endif()

if(TELAR_LINUX_DISTRIBUTABLE)
  find_library(SQLITE3_LIBRARY NAMES libsqlite3.a REQUIRED)
else()
  find_library(SQLITE3_LIBRARY NAMES sqlite3 REQUIRED)
endif()
if(TELAR_RUNTIME_DISTRIBUTABLE)
  set(OPENSSL_USE_STATIC_LIBS TRUE)
endif()
find_package(OpenSSL 3.0...<4.0 REQUIRED)

set(NGHTTP2_ROOT "" CACHE PATH "Installed nghttp2 prefix")
find_path(NGHTTP2_INCLUDE_DIR nghttp2/nghttp2.h HINTS "${NGHTTP2_ROOT}/include" REQUIRED)
find_library(NGHTTP2_LIBRARY NAMES libnghttp2.a nghttp2 HINTS "${NGHTTP2_ROOT}/lib" REQUIRED)

if(TELAR_LINUX_DISTRIBUTABLE)
  find_library(ZLIB_LIBRARY NAMES libz.a REQUIRED)
  find_library(PCAP_LIBRARY NAMES libpcap.a REQUIRED)
  # musl gives threads 128 KiB stacks unless the executable names a size;
  # the terminal engine needs glibc's 8 MiB.
  add_link_options(-static "LINKER:-z,stack-size=8388608")
  # A static executable cannot dlopen, so the CLI links SQLite for history.
  set(TELAR_LINKED_SQLITE ON)
else()
  find_library(ZLIB_LIBRARY NAMES z REQUIRED)
  find_library(PCAP_LIBRARY NAMES pcap PATHS "${CMAKE_OSX_SYSROOT}/usr/lib" REQUIRED)
endif()

set(BROTLI_ROOT "" CACHE PATH "Installed Brotli prefix")
find_path(BROTLI_INCLUDE_DIR brotli/decode.h HINTS "${BROTLI_ROOT}/include" REQUIRED)
find_library(BROTLI_DECODER_LIBRARY NAMES libbrotlidec.a brotlidec HINTS "${BROTLI_ROOT}/lib" REQUIRED)
find_library(BROTLI_ENCODER_LIBRARY NAMES libbrotlienc.a brotlienc HINTS "${BROTLI_ROOT}/lib" REQUIRED)
find_library(BROTLI_COMMON_LIBRARY NAMES libbrotlicommon.a brotlicommon HINTS "${BROTLI_ROOT}/lib" REQUIRED)

set(ZSTD_ROOT "" CACHE PATH "Installed Zstd prefix")
find_path(ZSTD_INCLUDE_DIR zstd.h HINTS "${ZSTD_ROOT}/include" REQUIRED)
find_library(ZSTD_LIBRARY NAMES libzstd.a zstd HINTS "${ZSTD_ROOT}/lib" REQUIRED)

# A static libcrypto may ask for zstd and zlib by name, which the linker would
# take from their shared libraries; hand it the static ones found above.
if(TELAR_LINUX_DISTRIBUTABLE)
  foreach(target IN ITEMS OpenSSL::Crypto OpenSSL::SSL)
    get_target_property(dependencies ${target} INTERFACE_LINK_LIBRARIES)
    if(dependencies)
      list(TRANSFORM dependencies REPLACE "^zstd$" "${ZSTD_LIBRARY}")
      list(TRANSFORM dependencies REPLACE "^z$" "${ZLIB_LIBRARY}")
      set_target_properties(${target} PROPERTIES INTERFACE_LINK_LIBRARIES "${dependencies}")
    endif()
  endforeach()
endif()

if(TELAR_RUNTIME_DISTRIBUTABLE)
  foreach(dependency IN ITEMS GHOSTTY_VT_LIBRARY NGHTTP2_LIBRARY BROTLI_DECODER_LIBRARY BROTLI_ENCODER_LIBRARY BROTLI_COMMON_LIBRARY ZSTD_LIBRARY OPENSSL_SSL_LIBRARY OPENSSL_CRYPTO_LIBRARY)
    if(NOT "${${dependency}}" MATCHES "\\.a$")
      message(FATAL_ERROR "${dependency} must be static for distribution; configure a fresh build directory with a static library prefix")
    endif()
  endforeach()
endif()
