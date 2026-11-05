cmake_minimum_required(VERSION 3.24)
set(CMAKE_OSX_DEPLOYMENT_TARGET "26.0" CACHE STRING "Minimum supported macOS version")
project(telar_runtime LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(TELAR_GHOSTTY_STATE_VERSION 6)

include(cmake/dependencies.cmake)
add_subdirectory(../../dlls/telar-tls "${CMAKE_CURRENT_BINARY_DIR}/telar-tls")

add_library(ghostty-vt UNKNOWN IMPORTED)
set_target_properties(ghostty-vt PROPERTIES
  IMPORTED_LOCATION "${GHOSTTY_VT_LIBRARY}"
  INTERFACE_INCLUDE_DIRECTORIES "${GHOSTTY_VT_INCLUDE_DIR}")

include(CheckCXXSourceCompiles)
set(CMAKE_REQUIRED_INCLUDES "${GHOSTTY_VT_INCLUDE_DIR}")
set(CMAKE_REQUIRED_LIBRARIES "${GHOSTTY_VT_LIBRARY}")
check_cxx_source_compiles("#include <ghostty/vt.h>
#include <cstddef>
int main() {
  static_assert(GHOSTTY_TELAR_STATE_VERSION == ${TELAR_GHOSTTY_STATE_VERSION});
  static_assert(sizeof(GhosttyTerminalCursorState) == 14);
  static_assert(offsetof(GhosttyTerminalCursorState, origin) == 12);
  static_assert(sizeof(GhosttyTerminalCursorSnapshot) == 16);
  static_assert(offsetof(GhosttyTerminalCursorSnapshot, valid) == 14);
  static_assert(offsetof(GhosttyTerminalCursorSnapshot, reserved) == 15);
  static_assert(alignof(GhosttyTerminalCursorSnapshot) == alignof(GhosttyTerminalCursorState));
  static_assert(sizeof(&ghostty_grid_ref_cells) > 0);
  static_assert(GHOSTTY_TELAR_ASCII_CODEPOINT_LIMIT == 4096);
  static_assert(sizeof(&ghostty_grid_ref_grapheme_batch) > 0);
  static_assert(sizeof(&ghostty_terminal_page_bytes) > 0);
  GhosttyCodepointsBuffer buffer{};
  GhosttyTerminalCursorState cursor{};
  const auto snapshot = ghostty_terminal_cursor_snapshot(nullptr);
  return static_cast<int>(snapshot.valid) + ghostty_terminal_vt_write_ascii(nullptr, nullptr, 0, nullptr) + ghostty_terminal_cursor_state(nullptr, &cursor) + buffer.len + sizeof(GhosttyKittyGraphicsImageInsert) + GHOSTTY_TERMINAL_DATA_CURSOR_IS_DEFAULT + GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_INTERNAL + GHOSTTY_TERMINAL_OPT_KITTY_PROTOCOL + GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_BOTTOM + GHOSTTY_KITTY_GRAPHICS_DATA_LOADING_BYTES + GHOSTTY_TERMINAL_OPT_ACTIVE_SCREEN;
}" GHOSTTY_VT_HAS_RUNTIME_STORAGE_STATE)
if(NOT GHOSTTY_VT_HAS_RUNTIME_STORAGE_STATE)
  message(FATAL_ERROR "Build the pinned libghostty-vt with tools/build_ghostty.py first")
endif()
set(CMAKE_REQUIRED_LIBRARIES "${GHOSTTY_VT_LIBRARY}")
check_cxx_source_compiles("#include <ghostty/wuffs-v0.4.h>
int main() {
  auto result = wuffs_png__decoder__initialize(nullptr, sizeof__wuffs_png__decoder(), WUFFS_VERSION, 0);
  return wuffs_base__status__is_ok(&result);
}" GHOSTTY_VT_HAS_WUFFS_PNG)
unset(CMAKE_REQUIRED_LIBRARIES)
unset(CMAKE_REQUIRED_INCLUDES)
if(NOT GHOSTTY_VT_HAS_WUFFS_PNG)
  message(FATAL_ERROR "The pinned VT archive must include its generic Wuffs PNG codec")
endif()

add_executable(ghostty-manifest tools/ghostty_manifest.cpp)
target_link_libraries(ghostty-manifest PRIVATE ghostty-vt)

file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/../../src/client/config/bootstrap.lua" TELAR_CONFIG_BOOTSTRAP)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/../../src/client/config/bootstrap.lua")
configure_file(config/bootstrap.hpp.in "${CMAKE_CURRENT_BINARY_DIR}/generated/config_bootstrap.hpp" @ONLY)
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/../../src/backend/plugins/bootstrap.lua" TELAR_PLUGIN_BOOTSTRAP)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/../../src/backend/plugins/bootstrap.lua")
configure_file(plugins/bootstrap.hpp.in "${CMAKE_CURRENT_BINARY_DIR}/generated/plugin_bootstrap.hpp" @ONLY)
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/plugins/traffic_api.lua" TELAR_TRAFFIC_API)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/plugins/traffic_api.lua")
configure_file(plugins/traffic_api.hpp.in "${CMAKE_CURRENT_BINARY_DIR}/generated/traffic_api.hpp" @ONLY)
add_custom_command(
  OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/generated/cell_layout.hpp"
  COMMAND Python3::Interpreter "${CMAKE_CURRENT_SOURCE_DIR}/tools/generate_cell_layout.py"
          "$<TARGET_FILE:ghostty-manifest>" "${CMAKE_CURRENT_BINARY_DIR}/generated/cell_layout.hpp"
  DEPENDS ghostty-manifest tools/generate_cell_layout.py
  VERBATIM)
add_custom_target(cell-layout DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/generated/cell_layout.hpp")

if(APPLE)
  set(TELAR_PLATFORM macos)
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  set(TELAR_PLATFORM linux)
else()
  message(FATAL_ERROR "The runtime supports macOS and Linux")
endif()

add_library(runtime-core STATIC
  graphics/png_decoder.cpp
  platform/process_inspector.cpp
  platform/${TELAR_PLATFORM}/process_inspector.cpp
  platform/${TELAR_PLATFORM}/host_metrics.cpp
  platform/local_listener.cpp
  history/database.cpp
  terminal/cell_projection.cpp)
set_target_properties(runtime-core telar-lua-vm telar-platform PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_include_directories(runtime-core PUBLIC . "${CMAKE_CURRENT_BINARY_DIR}/generated" "${TELAR_NATIVE_INCLUDE_DIR}")
target_link_libraries(runtime-core PUBLIC telar::tls)
target_link_libraries(runtime-core PUBLIC "${NGHTTP2_LIBRARY}")
target_link_libraries(runtime-core PUBLIC "${PCAP_LIBRARY}")
target_link_libraries(runtime-core PUBLIC "${ZLIB_LIBRARY}" "${BROTLI_DECODER_LIBRARY}" "${BROTLI_ENCODER_LIBRARY}" "${BROTLI_COMMON_LIBRARY}" "${ZSTD_LIBRARY}")
target_link_libraries(runtime-core PUBLIC ghostty-vt "${SQLITE3_LIBRARY}" Threads::Threads OpenSSL::SSL OpenSSL::Crypto)
if(APPLE)
  target_sources(runtime-core PRIVATE platform/macos/event_loop.cpp)
  target_link_libraries(runtime-core PUBLIC "-framework IOKit" "-framework CoreFoundation" "-framework Security")
else()
  target_compile_definitions(runtime-core PUBLIC _GNU_SOURCE)
  target_link_libraries(runtime-core PUBLIC util)
endif()
option(TELAR_RUNTIME_DIAGNOSTICS "Enable runtime telemetry outside Debug builds" OFF)
target_compile_definitions(runtime-core PUBLIC TELAR_DEBUG=$<CONFIG:Debug> TELAR_DIAGNOSTICS=$<OR:$<CONFIG:Debug>,$<BOOL:${TELAR_RUNTIME_DIAGNOSTICS}>>)
target_compile_options(runtime-core PUBLIC -Wall -Wextra -Wpedantic)
add_dependencies(runtime-core cell-layout)

include(CTest)
add_executable(telar-runtime main.cpp)
target_link_libraries(telar-runtime PRIVATE runtime-core)
install(TARGETS telar-runtime RUNTIME DESTINATION bin)
# The pinned libraries are linked into both executables; their licenses travel with them.
install(DIRECTORY "${TELAR_OPENSSL_PREFIX}/share/licenses/" "${TELAR_NATIVE_PREFIX}/share/licenses/" DESTINATION share/telar/licenses)

# `telar server` and the endpoint discovery start the runtime installed beside the CLI,
# and panes get the CLI beside the runtime, so both build into the same directory.
add_subdirectory(../cli-cpp "${CMAKE_CURRENT_BINARY_DIR}/cli")
set_target_properties(telar PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}")

option(TELAR_RUNTIME_SANITIZERS "Enable address and undefined behavior sanitizers" OFF)
if(TELAR_RUNTIME_SANITIZERS)
  if(TELAR_RUNTIME_DISTRIBUTABLE)
    message(FATAL_ERROR "Sanitizer builds require their compiler runtime and cannot use the distributable linkage check")
  endif()
  target_compile_options(telar-lua-vm PRIVATE -fsanitize=address,undefined -fno-omit-frame-pointer)
  target_compile_options(telar-platform PRIVATE -fsanitize=address,undefined -fno-omit-frame-pointer)
  target_compile_options(runtime-core PUBLIC -fsanitize=address,undefined -fno-omit-frame-pointer)
  target_link_options(runtime-core PUBLIC -fsanitize=address,undefined)
  target_compile_options(cli-core PUBLIC -fsanitize=address,undefined -fno-omit-frame-pointer)
  target_link_options(cli-core PUBLIC -fsanitize=address,undefined)
endif()

# The installed executables may link only the base system (glibc on Linux);
# every distributable build checks it.
if(TELAR_RUNTIME_DISTRIBUTABLE)
  set(TELAR_LINKAGE_KIND "$<IF:$<PLATFORM_ID:Darwin>,macos,linux-headless>")
  add_custom_target(distributable-linkage ALL
    COMMAND "${CMAKE_COMMAND}" -E env "TELAR_MACOS_MIN=${CMAKE_OSX_DEPLOYMENT_TARGET}"
            "${CMAKE_CURRENT_SOURCE_DIR}/../../packaging/release/check-linkage.sh" "${TELAR_LINKAGE_KIND}"
            "$<TARGET_FILE:telar-runtime>" "$<TARGET_FILE:telar>" "$<TARGET_FILE:telar-config-check>"
    DEPENDS telar-runtime telar telar-config-check
    VERBATIM)
endif()

if(BUILD_TESTING)
  include(cmake/tests.cmake)
endif()
