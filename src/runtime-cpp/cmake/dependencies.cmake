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

include("${CMAKE_CURRENT_LIST_DIR}/../../../cmake/openssl.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/../../../cmake/native_libraries.cmake")

# Earlier configurations searched the system for these; the managed build
# supplies them now.
foreach(variable IN ITEMS NGHTTP2_ROOT NGHTTP2_INCLUDE_DIR NGHTTP2_LIBRARY BROTLI_ROOT BROTLI_INCLUDE_DIR
    BROTLI_DECODER_LIBRARY BROTLI_ENCODER_LIBRARY BROTLI_COMMON_LIBRARY ZSTD_ROOT ZSTD_INCLUDE_DIR ZSTD_LIBRARY
    ZLIB_LIBRARY SQLITE3_LIBRARY PCAP_LIBRARY)
  unset(${variable} CACHE)
endforeach()

if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  # The CLI links the managed SQLite for history instead of loading whatever
  # the system has.
  set(TELAR_LINKED_SQLITE ON)
else()
  # macOS links the SDK's copies, which Apple patches with the OS, and never
  # a package manager's.
  set(sdk "${CMAKE_OSX_SYSROOT}")
  if(NOT IS_ABSOLUTE "${sdk}")
    if(NOT sdk)
      set(sdk macosx)
    endif()

    execute_process(COMMAND xcrun --sdk "${sdk}" --show-sdk-path
      OUTPUT_VARIABLE sdk OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
  endif()

  find_library(SQLITE3_LIBRARY NAMES sqlite3 PATHS "${sdk}/usr/lib" NO_DEFAULT_PATH REQUIRED)
  find_library(ZLIB_LIBRARY NAMES z PATHS "${sdk}/usr/lib" NO_DEFAULT_PATH REQUIRED)
  find_library(PCAP_LIBRARY NAMES pcap PATHS "${sdk}/usr/lib" NO_DEFAULT_PATH REQUIRED)
endif()

if(TELAR_LINUX_DISTRIBUTABLE)
  # musl gives threads 128 KiB stacks unless the executable names a size;
  # the terminal engine needs glibc's 8 MiB.
  add_link_options(-static "LINKER:-z,stack-size=8388608")
endif()

if(TELAR_RUNTIME_DISTRIBUTABLE AND NOT "${GHOSTTY_VT_LIBRARY}" MATCHES "\\.a$")
  message(FATAL_ERROR "GHOSTTY_VT_LIBRARY must be static for distribution; configure a fresh build directory with a static library prefix")
endif()
