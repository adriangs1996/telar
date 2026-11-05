cmake_minimum_required(VERSION 3.24)
project(telar_qt LANGUAGES C CXX)

include(ExternalProject)
include(manifest.cmake)
include("${TELAR_MANAGED_BUILD}")
find_program(TELAR_QT_PATCH patch REQUIRED)
set(TELAR_DOWNLOAD_DIR "${CMAKE_CURRENT_BINARY_DIR}/downloads" CACHE PATH "Verified Qt source archive cache")
set(CMAKE_INSTALL_PREFIX "${CMAKE_CURRENT_BINARY_DIR}/install" CACHE PATH "Private Qt installation" FORCE)

if(APPLE)
  set(CMAKE_OBJC_COMPILER "${CMAKE_C_COMPILER}")
  set(CMAKE_OBJCXX_COMPILER "${CMAKE_CXX_COMPILER}")
  enable_language(OBJC OBJCXX)
  include(CheckOBJCXXCompilerFlag)
  check_objcxx_compiler_flag(-fno-objc-msgsend-class-selector-stubs TELAR_QT_HAS_OBJC_CLASS_STUB_CONTROL)
  if(TELAR_QT_HAS_OBJC_CLASS_STUB_CONTROL)
    string(APPEND CMAKE_OBJC_FLAGS " -fno-objc-msgsend-class-selector-stubs")
    string(APPEND CMAKE_OBJCXX_FLAGS " -fno-objc-msgsend-class-selector-stubs")
  endif()
endif()

telar_forwarded_toolchain(toolchain)
set(qt_arguments
  ${toolchain}
  "-DCMAKE_INSTALL_PREFIX:PATH=${CMAKE_INSTALL_PREFIX}"
  "-DCMAKE_BUILD_TYPE:STRING=Release"
  "-DBUILD_SHARED_LIBS:BOOL=ON"
  "-DQT_BUILD_TESTS:BOOL=OFF"
  "-DQT_BUILD_EXAMPLES:BOOL=OFF"
  "-DQT_BUILD_BENCHMARKS:BOOL=OFF"
  "-DQT_HOST_PATH:PATH="
  "-DCMAKE_PREFIX_PATH:PATH=${CMAKE_INSTALL_PREFIX}"
  "-DQT_ADDITIONAL_PACKAGES_PREFIX_PATH:PATH=${CMAKE_INSTALL_PREFIX}")

set(base_arguments
  -DFEATURE_widgets:BOOL=OFF
  -DFEATURE_printsupport:BOOL=OFF
  -DFEATURE_sql:BOOL=OFF
  -DFEATURE_system_zlib:BOOL=OFF
  -DFEATURE_system_pcre2:BOOL=OFF
  -DFEATURE_system_doubleconversion:BOOL=OFF
  -DFEATURE_system_libb2:BOOL=OFF
  -DFEATURE_system_freetype:BOOL=OFF
  -DFEATURE_system_harfbuzz:BOOL=OFF
  -DFEATURE_system_jpeg:BOOL=OFF
  -DFEATURE_system_png:BOOL=OFF
  -DFEATURE_system_textmarkdownreader:BOOL=OFF
  -DFEATURE_icu:BOOL=OFF
  # The client reaches its runtime over local sockets only; Qt's TLS would
  # load whichever OpenSSL the system has.
  -DFEATURE_openssl:BOOL=OFF
  -DFEATURE_brotli:BOOL=OFF
  -DFEATURE_zstd:BOOL=OFF)
if(APPLE)
  list(APPEND base_arguments -DFEATURE_vulkan:BOOL=OFF)
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  list(APPEND base_arguments -DFEATURE_fontconfig:BOOL=ON -DFEATURE_xcb:BOOL=ON -DFEATURE_vulkan:BOOL=ON)
else()
  message(FATAL_ERROR "The managed Qt build supports native macOS and Linux builds")
endif()

function(telar_qt_module module)
  cmake_parse_arguments(MODULE "" "" "DEPENDS;ARGUMENTS;PATCH_COMMAND" ${ARGN})
  ExternalProject_Add(${module}
    URL "${TELAR_QT_SOURCE_URL}/${module}-everywhere-src-${TELAR_QT_VERSION}.tar.xz"
    URL_HASH "SHA256=${TELAR_QT_SHA256_${module}}"
    TLS_VERIFY TRUE
    DOWNLOAD_DIR "${TELAR_DOWNLOAD_DIR}"
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    UPDATE_COMMAND ""
    PATCH_COMMAND ${MODULE_PATCH_COMMAND}
    CMAKE_GENERATOR Ninja
    LIST_SEPARATOR "|"
    CMAKE_ARGS ${qt_arguments} ${MODULE_ARGUMENTS}
    DEPENDS ${MODULE_DEPENDS}
    INSTALL_COMMAND "${CMAKE_COMMAND}" --install <BINARY_DIR>
      COMMAND "${CMAKE_COMMAND}" -E copy_directory <SOURCE_DIR>/LICENSES "${CMAKE_INSTALL_PREFIX}/share/licenses/qt/${module}"
    USES_TERMINAL_DOWNLOAD TRUE
    USES_TERMINAL_CONFIGURE TRUE
    USES_TERMINAL_BUILD TRUE
    USES_TERMINAL_INSTALL TRUE)
endfunction()

telar_qt_module(qtbase ARGUMENTS ${base_arguments}
  PATCH_COMMAND "${CMAKE_COMMAND}"
    "-DSOURCE_DIR=<SOURCE_DIR>"
    "-DDOWNLOAD_DIR=${TELAR_DOWNLOAD_DIR}"
    "-DPATCH_EXECUTABLE=${TELAR_QT_PATCH}"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/patch.cmake")
telar_qt_module(qtshadertools DEPENDS qtbase)
telar_qt_module(qtdeclarative DEPENDS qtshadertools)
telar_qt_module(qtsvg DEPENDS qtbase)
set(qt_modules qtbase qtshadertools qtdeclarative qtsvg)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  telar_qt_module(qtwayland DEPENDS qtdeclarative
    ARGUMENTS -DFEATURE_wayland_client:BOOL=ON -DFEATURE_wayland_server:BOOL=ON)
  list(APPEND qt_modules qtwayland)
endif()
add_custom_target(telar-qt DEPENDS ${qt_modules})
file(MAKE_DIRECTORY "${CMAKE_INSTALL_PREFIX}/share/licenses/qt")
configure_file(manifest.cmake "${CMAKE_INSTALL_PREFIX}/share/licenses/qt/manifest.cmake" COPYONLY)
