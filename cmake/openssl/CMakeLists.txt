cmake_minimum_required(VERSION 3.24)
project(telar_openssl LANGUAGES C)

include(ExternalProject)
include(manifest.cmake)
find_program(TELAR_OPENSSL_PERL perl REQUIRED)
find_program(TELAR_OPENSSL_MAKE NAMES gmake make REQUIRED)
find_program(TELAR_OPENSSL_PATCH patch REQUIRED)
set(TELAR_DOWNLOAD_DIR "${CMAKE_CURRENT_BINARY_DIR}/downloads" CACHE PATH "Verified OpenSSL source archive cache")
set(TELAR_MANAGED_JOBS 1 CACHE STRING "Parallel compiler jobs")
set(CMAKE_INSTALL_PREFIX "${CMAKE_CURRENT_BINARY_DIR}/install" CACHE PATH "Private OpenSSL installation" FORCE)

# Static libraries with the providers built in: telar links them into its
# executables and loads nothing at run time. OPENSSLDIR is where Linux keeps
# its certificate bundle and configuration; telar loads no configuration.
set(options
  no-shared no-module no-apps no-docs no-tests
  "--prefix=${CMAKE_INSTALL_PREFIX}" --libdir=lib --openssldir=/etc/ssl
  -DDO_NOT_SKIP_OPENSSL_CLEANUP)
separate_arguments(flags UNIX_COMMAND "${CMAKE_C_FLAGS}")
list(APPEND options ${flags})
if(APPLE)
  list(LENGTH CMAKE_OSX_ARCHITECTURES architectures)
  if(architectures GREATER 1)
    message(FATAL_ERROR "The managed OpenSSL build supports one macOS architecture at a time")
  endif()

  if(CMAKE_OSX_ARCHITECTURES)
    list(APPEND options -arch "${CMAKE_OSX_ARCHITECTURES}")
  endif()

  if(CMAKE_OSX_DEPLOYMENT_TARGET)
    list(APPEND options "-mmacosx-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET}")
  endif()

  if(CMAKE_OSX_SYSROOT)
    list(APPEND options -isysroot "${CMAKE_OSX_SYSROOT}")
  endif()
elseif(NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
  message(FATAL_ERROR "The managed OpenSSL build supports native macOS and Linux builds")
endif()

ExternalProject_Add(openssl
  URL "${TELAR_OPENSSL_URL}"
  URL_HASH "SHA256=${TELAR_OPENSSL_SHA256}"
  TLS_VERIFY TRUE
  DOWNLOAD_DIR "${TELAR_DOWNLOAD_DIR}"
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  UPDATE_COMMAND ""
  # OpenSSL 4.1 writes generated headers into its source tree when apps are disabled.
  BUILD_IN_SOURCE TRUE
  PATCH_COMMAND "${TELAR_OPENSSL_PATCH}" -p1 --forward --input "${CMAKE_CURRENT_SOURCE_DIR}/immediate-cleanup.patch"
  CONFIGURE_COMMAND "${CMAKE_COMMAND}" -E env "CC=${CMAKE_C_COMPILER}"
    "${TELAR_OPENSSL_PERL}" <SOURCE_DIR>/Configure ${options}
  BUILD_COMMAND "${TELAR_OPENSSL_MAKE}" "-j${TELAR_MANAGED_JOBS}" build_libs
  INSTALL_COMMAND "${TELAR_OPENSSL_MAKE}" install_dev
    COMMAND "${CMAKE_COMMAND}" -E copy <SOURCE_DIR>/LICENSE.txt "${CMAKE_INSTALL_PREFIX}/share/licenses/openssl/LICENSE.txt"
  USES_TERMINAL_DOWNLOAD TRUE
  USES_TERMINAL_CONFIGURE TRUE
  USES_TERMINAL_BUILD TRUE
  USES_TERMINAL_INSTALL TRUE)
add_custom_target(telar-openssl DEPENDS openssl)
