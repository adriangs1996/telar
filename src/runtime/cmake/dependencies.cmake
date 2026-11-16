# The runtime's checks of libghostty-vt's state ABI rerun when that ABI's version changes;
# cmake/deps/ghostty.cmake reruns them for another prefix.
if(NOT "${TELAR_LAST_GHOSTTY_STATE_VERSION}" STREQUAL "${TELAR_GHOSTTY_STATE_VERSION}")
  unset(GHOSTTY_VT_HAS_RUNTIME_STORAGE_STATE CACHE)
  unset(GHOSTTY_VT_HAS_WUFFS_PNG CACHE)
endif()
set(TELAR_LAST_GHOSTTY_STATE_VERSION "${TELAR_GHOSTTY_STATE_VERSION}" CACHE INTERNAL "State ABI used for the VT feature checks" FORCE)

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

if(TELAR_RUNTIME_DISTRIBUTABLE AND NOT "${GHOSTTY_VT_LIBRARY}" MATCHES "\\.a$")
  message(FATAL_ERROR "GHOSTTY_VT_LIBRARY must be static for distribution; configure a fresh build directory with a static library prefix")
endif()
