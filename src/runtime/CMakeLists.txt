cmake_minimum_required(VERSION 4.4.5)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
set(CMAKE_OSX_DEPLOYMENT_TARGET "26.0" CACHE STRING "Minimum supported macOS version")
project(telar_runtime LANGUAGES C CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/cpp_modules.cmake")

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(TELAR_GHOSTTY_STATE_VERSION 6)

include(cmake/dependencies.cmake)
add_subdirectory(../../lib/config "${CMAKE_CURRENT_BINARY_DIR}/telar-config")
add_subdirectory(../../lib/tls "${CMAKE_CURRENT_BINARY_DIR}/telar-tls")
add_subdirectory(../../lib/native "${CMAKE_CURRENT_BINARY_DIR}/telar-native")

add_library(ghostty-vt UNKNOWN IMPORTED)
set_target_properties(ghostty-vt PROPERTIES
  IMPORTED_LOCATION "${GHOSTTY_VT_LIBRARY}"
  INTERFACE_INCLUDE_DIRECTORIES "${GHOSTTY_VT_INCLUDE_DIR}")

# Static headless distribution builds must not acquire desktop dependencies.
if(TELAR_LINUX_DISTRIBUTABLE)
  option(TELAR_CLIPBOARD_NATIVE "Build native graphical-session clipboard access" OFF)
endif()
include("${CMAKE_CURRENT_SOURCE_DIR}/../../lib/clipboard/cmake/library.cmake")

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
# The remote command `ssh` sends is encoded at compile time, which takes more steps than the
# compiler allows by default.
set_source_files_properties(shell_integration/shell_integration.cppm PROPERTIES COMPILE_OPTIONS "-fconstexpr-steps=16777216")
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

if(APPLE)
  set(TELAR_PLATFORM macos)
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  set(TELAR_PLATFORM linux)
else()
  message(FATAL_ERROR "The runtime supports macOS and Linux")
endif()

add_library(runtime-core STATIC
  cli/server/server.cpp
  config/loader/loader.cpp
  diagnostics/line/line.cpp
  diagnostics/operation/operation.cpp
  diagnostics/runtime_counters/runtime_counters.cpp
  graphics/file_input/file_input.cpp
  graphics/pane_media/pane_media.cpp
  graphics/png_decoder.cpp
  graphics/prepared_images/prepared_images.cpp
  graphics/synchronizer/synchronizer.cpp
  history/store/database.cpp
  metrics/host_sampler/host_sampler.cpp
  model/client_layouts/client_layouts.cpp
  model/client_layouts/client_layouts-launch_record.cpp
  model/slot_store/slot_store.cpp
  observation/processor/processor.cpp
  paths/query_task/query_task.cpp
  persistence/session_store/session_store.cpp
  platform/background_executor/background_executor.cpp
  platform/descriptor_path/descriptor_path.cpp
  platform/event_loop/${TELAR_PLATFORM}/event_loop.cpp
  platform/git_status/git_status.cpp
  platform/host_metrics/${TELAR_PLATFORM}/host_metrics.cpp
  platform/launch_program/launch_program.cpp
  platform/local_listener/local_listener.cpp
  platform/name_resolutions/name_resolutions.cpp
  platform/private_tunnel/private_tunnel.cpp
  platform/process_probe/${TELAR_PLATFORM}/process_inspector.cpp
  platform/process_probe/process_inspector.cpp
  platform/request_worker/request_worker.cpp
  platform/session_host/session_host.cpp
  platform/signals/signals.cpp
  platform/stream_read_buffer/stream_read_buffer.cpp
  platform/system_certificates/system_certificates.cpp
  runtime/client_control/client_control.cpp
  runtime/delivery/client_delivery/client_delivery.cpp
  runtime/execution_service/execution_service-execution.cpp
  runtime/execution_service/execution_service.cpp
  runtime/media_service/media_service.cpp
  runtime/runtime/runtime.cpp
  runtime/runtime_telemetry/runtime_telemetry.cpp
  terminal/control/checksum/checksum.cpp
  terminal/control/clipboard/clipboard.cpp
  terminal/control/control.cpp
  terminal/control/engine/engine.cpp
  terminal/control/glyph/glyph.cpp
  terminal/control/graphics_payload.cpp
  terminal/control/pty_response_queue.cpp
  terminal/control/vt_state.cpp
  terminal/ghostty/ghostty.cpp
  terminal/graphics_storage/graphics_storage.cpp
  terminal/kitty/kitty.cpp
  terminal/osc_scanner/osc_scanner.cpp
  terminal/text_reader/cell_projection.cpp
  terminal/text_reader/text_reader.cpp
  transport/connection/connection.cpp
  vocabulary/exchange/exchange.cpp
  vocabulary/frames/frames.cpp
  vocabulary/traffic/traffic.cpp
  agents/description_generator/description_generator.cpp
  agents/screen_inference/screen_inference.cpp
  agents/snapshot/snapshot.cpp
  command_capture/tracker/tracker.cpp
  editors/remote_editor/remote_editor.cpp
  history/event/event.cpp
  history/store/store.cpp
  shell_integration/git_context/git_context.cpp
  shell_integration/shell_integration.cpp
  shell_integration/token/token.cpp
  shell_integration/words/words.cpp
  suggestions/engine/engine.cpp
  workspaces/git_probe/git_probe.cpp
  worktrees/git_probe/git_probe.cpp)
# The traffic domain: proxy, TLS interception, HTTP, redirection, capture and plugins.
target_sources(runtime-core PRIVATE
  exchange_capture/pipeline/pipeline.cpp
  exchange_capture/producer/producer.cpp
  http/content/content.cpp
  http/message/message.cpp
  http1/head/head.cpp
  http2/direction_observer/direction_observer.cpp
  http2/frame_reader/frame_reader.cpp
  plugins/run_worker/run_worker.cpp
  plugins/service/service.cpp
  plugins/tap_configuration/tap_configuration.cpp
  plugins/worker/worker.cpp
  proxy/authenticate/authenticate.cpp
  proxy/http2_capture_streams/http2_capture_streams.cpp
  proxy/intercepted_relay/intercepted_relay.cpp
  proxy/runtime/runtime.cpp
  redirect/direction/direction.cpp
  redirect/ingress/ingress.cpp
  redirect/pf_rules/pf_rules.cpp
  redirect/socket_owners/socket_owners.cpp
  tls/interception/interception.cpp
  tls/system_root_bundle/system_root_bundle.cpp
  traffic/capture/capture.cpp
  traffic/capture_analysis/capture_analysis.cpp
  traffic/control_backend/control_backend.cpp
  traffic/control_protocol/control_protocol.cpp)
telar_modules(runtime-core)
set_target_properties(runtime-core telar-lua-vm telar-platform PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_include_directories(runtime-core PUBLIC . "${CMAKE_CURRENT_BINARY_DIR}/generated" "${CMAKE_CURRENT_SOURCE_DIR}/../../lib/tbc/include")
# Third-party headers, as the other dependencies': the project neither warns about nor annotates them.
target_include_directories(runtime-core SYSTEM PUBLIC "${TELAR_NATIVE_INCLUDE_DIR}")
if(NOT TARGET telar-render)
  add_subdirectory(../../lib/render "${CMAKE_CURRENT_BINARY_DIR}/telar-render")
endif()
target_link_libraries(runtime-core PUBLIC telar::config telar::native telar::tls telar-clipboard telar::render)
target_link_libraries(runtime-core PUBLIC "${NGHTTP2_LIBRARY}")
target_link_libraries(runtime-core PUBLIC "${PCAP_LIBRARY}")
add_subdirectory(../../lib/git "${CMAKE_CURRENT_BINARY_DIR}/telar-git")
target_link_libraries(runtime-core PUBLIC telar::git)
add_subdirectory(../../lib/ebnf "${CMAKE_CURRENT_BINARY_DIR}/ebnf")
target_link_libraries(runtime-core PUBLIC ebnf::ebnf)
target_link_libraries(runtime-core PUBLIC "${ZLIB_LIBRARY}" "${BROTLI_DECODER_LIBRARY}" "${BROTLI_ENCODER_LIBRARY}" "${BROTLI_COMMON_LIBRARY}" "${ZSTD_LIBRARY}")
target_link_libraries(runtime-core PUBLIC ghostty-vt "${SQLITE3_LIBRARY}" Threads::Threads OpenSSL::SSL OpenSSL::Crypto)
if(APPLE)
  target_link_libraries(runtime-core PUBLIC "-framework IOKit" "-framework CoreFoundation" "-framework Security")
  # The interface of telar.runtime.redirect.record is macOS only (cmake/module_platforms.cmake).
  target_sources(runtime-core PRIVATE redirect/record/record.cpp)
else()
  target_compile_definitions(runtime-core PUBLIC _GNU_SOURCE)
  target_sources(runtime-core PRIVATE platform/proc_file/proc_file.cpp)
  target_link_libraries(runtime-core PUBLIC util)
endif()
option(TELAR_RUNTIME_DIAGNOSTICS "Enable runtime telemetry outside Debug builds" OFF)

target_compile_options(runtime-core PUBLIC -Wall -Wextra -Wpedantic)
add_dependencies(runtime-core cell-layout command-specs)

include(CTest)
add_executable(telar-runtime main.cpp)
target_link_libraries(telar-runtime PRIVATE runtime-core)
install(TARGETS telar-runtime RUNTIME DESTINATION bin)
# The pinned libraries are linked into both executables; their licenses travel with them.
install(DIRECTORY "${TELAR_OPENSSL_PREFIX}/share/licenses/" "${TELAR_NATIVE_PREFIX}/share/licenses/" DESTINATION share/telar/licenses)

# `telar server` and the endpoint discovery start the runtime installed beside the CLI,
# and panes get the CLI beside the runtime, so both build into the same directory.
add_subdirectory(../cli "${CMAKE_CURRENT_BINARY_DIR}/cli")
set_target_properties(telar PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}")

option(TELAR_RUNTIME_SANITIZERS "Enable address and undefined behavior sanitizers" OFF)
if(TELAR_SANITIZERS AND TELAR_RUNTIME_DISTRIBUTABLE)
  message(FATAL_ERROR "Sanitizer builds require their compiler runtime and cannot use the distributable linkage check")
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
