telar_process(runtime OPTIONS -Wall -Wextra -Wpedantic)

set(TELAR_GHOSTTY_STATE_VERSION 6)

include(cmake/dependencies.cmake)

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
target_link_libraries(ghostty-manifest PRIVATE deps::ghostty_vt telar::build_flags)

file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(REAL_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../../lib/config/bootstrap.lua" telar_config_bootstrap_file)
file(READ "${telar_config_bootstrap_file}" TELAR_CONFIG_BOOTSTRAP)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${telar_config_bootstrap_file}")
configure_file(config/bootstrap.inc.in "${CMAKE_CURRENT_BINARY_DIR}/generated/config_bootstrap.inc" @ONLY)
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/plugins/bootstrap.lua" TELAR_PLUGIN_BOOTSTRAP)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/plugins/bootstrap.lua")
configure_file(plugins/bootstrap.inc.in "${CMAKE_CURRENT_BINARY_DIR}/generated/plugin_bootstrap.inc" @ONLY)
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/plugins/traffic_api.lua" TELAR_TRAFFIC_API)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/plugins/traffic_api.lua")
configure_file(plugins/traffic_api.inc.in "${CMAKE_CURRENT_BINARY_DIR}/generated/traffic_api.inc" @ONLY)
# The shell integration scripts are compiled in: remote hosts receive only the executables.
foreach(script IN ITEMS "ZSHENV=zshenv.zsh" "ZSH=telar.zsh" "BASH=telar.bash" "FISH=telar.fish" "SSH=ssh.sh" "REMOTE=remote.sh")
  string(REPLACE "=" ";" script "${script}")
  list(GET script 0 script_name)
  list(GET script 1 script_file)
  file(READ "${CMAKE_CURRENT_SOURCE_DIR}/shell_integration/${script_file}" TELAR_SHELL_${script_name})
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/shell_integration/${script_file}")
endforeach()
configure_file(shell_integration/scripts.inc.in "${CMAKE_CURRENT_BINARY_DIR}/generated/shell_scripts.inc" @ONLY)
add_custom_command(
  OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/generated/cell_layout.inc"
  COMMAND Python3::Interpreter "${CMAKE_CURRENT_SOURCE_DIR}/tools/generate_cell_layout.py"
          "$<TARGET_FILE:ghostty-manifest>" "${CMAKE_CURRENT_BINARY_DIR}/generated/cell_layout.inc"
  DEPENDS ghostty-manifest tools/generate_cell_layout.py
  VERBATIM)
add_custom_target(cell-layout DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/generated/cell_layout.inc")
# The completion specs the runtime offers: lib/ebnf/specs, and telar's own, written from the
# CLI's help files so it lists the commands this build has.
file(GLOB telar_command_spec_files CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/../../lib/ebnf/specs/*.ebnf")
file(GLOB_RECURSE telar_cli_help_files CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/../cli/help/*.txt")
add_custom_command(
  OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/generated/command_specs.inc"
  COMMAND Python3::Interpreter "${CMAKE_CURRENT_SOURCE_DIR}/tools/generate_command_specs.py"
          --specs "${CMAKE_CURRENT_SOURCE_DIR}/../../lib/ebnf/specs"
          --help-dir "${CMAKE_CURRENT_SOURCE_DIR}/../cli/help"
          --output "${CMAKE_CURRENT_BINARY_DIR}/generated/command_specs.inc"
  DEPENDS tools/generate_command_specs.py ${telar_command_spec_files} ${telar_cli_help_files}
  VERBATIM)
add_custom_target(command-specs DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/generated/command_specs.inc")

if(NOT APPLE AND NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
  message(FATAL_ERROR "The runtime supports macOS and Linux")
endif()

# What every domain of the runtime compiles and links with.
target_include_directories(runtime-settings INTERFACE . "${CMAKE_CURRENT_BINARY_DIR}/generated")
# Third-party headers, as the other dependencies': the project neither warns about nor annotates them.
target_include_directories(runtime-settings SYSTEM INTERFACE "${TELAR_NATIVE_INCLUDE_DIR}")
target_link_libraries(runtime-settings INTERFACE tbc::tbc telar::config telar::native telar::tls telar-clipboard telar::render)
target_link_libraries(runtime-settings INTERFACE deps::nghttp2)
target_link_libraries(runtime-settings INTERFACE deps::pcap)
target_link_libraries(runtime-settings INTERFACE telar::git)
target_link_libraries(runtime-settings INTERFACE ebnf::ebnf)
target_link_libraries(runtime-settings INTERFACE deps::zlib deps::brotli_decoder deps::brotli_encoder deps::brotli_common deps::zstd)
target_link_libraries(runtime-settings INTERFACE deps::ghostty_vt deps::sqlite3 Threads::Threads OpenSSL::SSL OpenSSL::Crypto)
if(APPLE)
  target_link_libraries(runtime-settings INTERFACE "-framework IOKit" "-framework CoreFoundation" "-framework Security")
else()
  target_compile_definitions(runtime-settings INTERFACE _GNU_SOURCE)
  target_link_libraries(runtime-settings INTERFACE util)
endif()

# The domains of docs/build/modules.json (process_layers), lowest first.
foreach(domain IN ITEMS diagnostics transport config suggestions platform paths shell_integration
    workspaces worktrees metrics terminal history command_capture graphics agents vocabulary
    observation model http1 http exchange_capture http2 tls redirect traffic proxy plugins editors
    persistence runtime cli)
  add_subdirectory(${domain})
endforeach()

add_executable(telar-runtime main.cpp)
target_link_libraries(telar-runtime PRIVATE runtime-terminal runtime-plugins runtime-cli)
telar_register_checks(telar-runtime ghostty-manifest CHECKS ${TELAR_CHECKS})
install(TARGETS telar-runtime RUNTIME DESTINATION bin)
# The pinned libraries are linked into both executables; their licenses travel with them.
install(DIRECTORY "${TELAR_OPENSSL_PREFIX}/share/licenses/" "${TELAR_NATIVE_PREFIX}/share/licenses/" DESTINATION share/telar/licenses)

if(BUILD_TESTING)
  add_subdirectory(tests)
endif()
