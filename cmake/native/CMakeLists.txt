cmake_minimum_required(VERSION 3.24)
project(telar_native LANGUAGES C)

include(ExternalProject)
include(manifest.cmake)
include("${TELAR_MANAGED_BUILD}")
set(TELAR_DOWNLOAD_DIR "${CMAKE_CURRENT_BINARY_DIR}/downloads" CACHE PATH "Verified source archive cache")
set(CMAKE_INSTALL_PREFIX "${CMAKE_CURRENT_BINARY_DIR}/install" CACHE PATH "Private installation" FORCE)

telar_forwarded_toolchain(toolchain)
set(common_arguments
  ${toolchain}
  "-DCMAKE_INSTALL_PREFIX:PATH=${CMAKE_INSTALL_PREFIX}"
  "-DCMAKE_INSTALL_LIBDIR:PATH=lib"
  "-DCMAKE_BUILD_TYPE:STRING=Release"
  "-DCMAKE_POSITION_INDEPENDENT_CODE:BOOL=ON"
  "-DBUILD_SHARED_LIBS:BOOL=OFF"
  "-DBUILD_TESTING:BOOL=OFF")

# telar_native_library(name NOTICE file [DOWNLOAD_NAME file] [SOURCE_SUBDIR dir] [PATCH_COMMAND ...] [ARGUMENTS ...])
# builds one static library from the source pinned in manifest.cmake and
# installs its license under share/licenses/name.
function(telar_native_library name)
  cmake_parse_arguments(LIBRARY "" "NOTICE;DOWNLOAD_NAME;SOURCE_SUBDIR" "PATCH_COMMAND;ARGUMENTS" ${ARGN})
  string(TOUPPER "${name}" key)
  set(download_name)
  if(LIBRARY_DOWNLOAD_NAME)
    set(download_name DOWNLOAD_NAME "${LIBRARY_DOWNLOAD_NAME}")
  endif()

  set(install "${CMAKE_COMMAND}" --install <BINARY_DIR>)
  if(LIBRARY_NOTICE)
    list(APPEND install COMMAND "${CMAKE_COMMAND}" -E copy <SOURCE_DIR>/${LIBRARY_NOTICE}
      "${CMAKE_INSTALL_PREFIX}/share/licenses/${name}/${LIBRARY_NOTICE}")
  endif()

  ExternalProject_Add(${name}
    URL "${TELAR_${key}_URL}"
    URL_HASH "SHA256=${TELAR_${key}_SHA256}"
    TLS_VERIFY TRUE
    DOWNLOAD_DIR "${TELAR_DOWNLOAD_DIR}"
    ${download_name}
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    UPDATE_COMMAND ""
    PATCH_COMMAND ${LIBRARY_PATCH_COMMAND}
    SOURCE_SUBDIR "${LIBRARY_SOURCE_SUBDIR}"
    CMAKE_GENERATOR Ninja
    LIST_SEPARATOR "|"
    CMAKE_ARGS ${common_arguments} ${LIBRARY_ARGUMENTS}
    INSTALL_COMMAND ${install}
    USES_TERMINAL_DOWNLOAD TRUE
    USES_TERMINAL_CONFIGURE TRUE
    USES_TERMINAL_BUILD TRUE
    USES_TERMINAL_INSTALL TRUE)
endfunction()

telar_native_library(nghttp2 NOTICE COPYING
  ARGUMENTS -DENABLE_LIB_ONLY:BOOL=ON -DBUILD_STATIC_LIBS:BOOL=ON -DENABLE_DOC:BOOL=OFF -DENABLE_FAILMALLOC:BOOL=OFF)
# The tag archive is named after the tag alone.
telar_native_library(brotli NOTICE LICENSE DOWNLOAD_NAME "brotli-${TELAR_BROTLI_VERSION}.tar.gz"
  ARGUMENTS -DBROTLI_BUILD_TOOLS:BOOL=OFF -DBROTLI_DISABLE_TESTS:BOOL=ON)
telar_native_library(zstd NOTICE LICENSE SOURCE_SUBDIR build/cmake
  ARGUMENTS -DZSTD_BUILD_SHARED:BOOL=OFF -DZSTD_BUILD_PROGRAMS:BOOL=OFF -DZSTD_BUILD_TESTS:BOOL=OFF)
set(libraries nghttp2 brotli zstd)

if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  telar_native_library(zlib NOTICE LICENSE
    ARGUMENTS -DZLIB_BUILD_SHARED:BOOL=OFF -DZLIB_BUILD_TESTING:BOOL=OFF)
  # The amalgamation ships no build system. SQLite is in the public domain.
  telar_native_library(sqlite
    PATCH_COMMAND "${CMAKE_COMMAND}" -E copy "${CMAKE_CURRENT_SOURCE_DIR}/sqlite.cmake" <SOURCE_DIR>/CMakeLists.txt)
  # Capture on ordinary network interfaces only. D-Bus, RDMA, Bluetooth,
  # netlink, netmap and capture cards would link more libraries into a static
  # executable.
  find_program(TELAR_NATIVE_FLEX flex REQUIRED)
  find_program(TELAR_NATIVE_BISON bison REQUIRED)
  telar_native_library(libpcap NOTICE LICENSE
    ARGUMENTS -DDISABLE_DBUS:BOOL=ON -DDISABLE_RDMA:BOOL=ON -DDISABLE_BLUETOOTH:BOOL=ON
      -DBUILD_WITH_LIBNL:BOOL=OFF -DDISABLE_NETMAP:BOOL=ON -DDISABLE_DAG:BOOL=ON -DDISABLE_SNF:BOOL=ON
      -DENABLE_REMOTE:BOOL=OFF "-DLEX_EXECUTABLE:FILEPATH=${TELAR_NATIVE_FLEX}" "-DYACC_EXECUTABLE:FILEPATH=${TELAR_NATIVE_BISON}")
  list(APPEND libraries zlib sqlite libpcap)
elseif(NOT APPLE)
  message(FATAL_ERROR "The managed native libraries support native macOS and Linux builds")
endif()

add_custom_target(telar-native DEPENDS ${libraries})
