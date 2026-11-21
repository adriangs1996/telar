cmake_minimum_required(VERSION 4.4.5)
include(cmake/TelarToolchain.cmake)
project(telar LANGUAGES C CXX)
# Objective-C and Objective-C++ build the macOS clipboard and window code. A
# language is enabled above every target that links objects compiled in it, here
# the runtime's and the GUI's programs.
if(APPLE)
  enable_language(OBJC OBJCXX)
endif()

# The processes this tree builds. Every library under lib/ is configured; a
# process links the ones it imports.
option(TELAR_BUILD_RUNTIME "Build the runtime and the CLI it ships with" ON)
option(TELAR_BUILD_CLI "Build the CLI" ON)
option(TELAR_BUILD_GUI "Build the GUI" ON)
option(TELAR_BUILD_AUTH "Build the auth daemon" ON)
if(TELAR_BUILD_RUNTIME AND NOT TELAR_BUILD_CLI)
  message(
    FATAL_ERROR
      "The runtime and the CLI start each other from the same directory; TELAR_BUILD_RUNTIME needs TELAR_BUILD_CLI"
  )
endif()

include(cmake/TelarTargets.cmake)
include(CTest)
telar_checks()

# A distributable runtime may link only the base system, which the dist preset
# checks. Linux has no base system: there it is a static musl executable, so it
# starts on any distribution, Alpine included. glibc cannot link statically
# everything it needs, so that build runs on musl (Alpine).
option(TELAR_RUNTIME_DISTRIBUTABLE
  "Require static non-system dependencies for installation" OFF
)

if(TELAR_SANITIZERS AND TELAR_RUNTIME_DISTRIBUTABLE)
  message(
    FATAL_ERROR
    "Sanitizer builds require their compiler runtime and cannot use the distributable linkage check"
  )
endif()

set(TELAR_LINUX_DISTRIBUTABLE OFF)

if(TELAR_RUNTIME_DISTRIBUTABLE AND CMAKE_SYSTEM_NAME STREQUAL "Linux")
  set(TELAR_LINUX_DISTRIBUTABLE ON)
  include(CheckCXXSourceCompiles)
  check_cxx_source_compiles(
    "#include <cstdio>
#if defined(__GLIBC__)
#error glibc
#endif
int main() {}"
    TELAR_MUSL)
  if(NOT TELAR_MUSL)
    message(
      FATAL_ERROR
        "The Linux distributable build links statically against musl; build it on Alpine"
    )
  endif()
  if(TELAR_BUILD_GUI OR TELAR_BUILD_AUTH)
    message(
      FATAL_ERROR
        "The Linux distributable build is the runtime and the CLI only; configure it with the dist preset"
    )
  endif()
endif()

# The pinned dependencies, prepared once for the whole tree: their targets are
# global and the prefixes and header directories they set reach every folder
# from here.
include(cmake/openssl.cmake)
include(cmake/deps/native.cmake)
include(cmake/deps/ghostty.cmake)

# What the release ships installs as the telar component; lib/ sets the telar-base
# development package apart, which a release leaves out.
set(CMAKE_INSTALL_DEFAULT_COMPONENT_NAME telar)
add_subdirectory(lib)
add_subdirectory(src)

