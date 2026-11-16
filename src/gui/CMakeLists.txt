cmake_minimum_required(VERSION 4.4.5)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_gui LANGUAGES C CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/cpp_modules.cmake")

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(TELAR_GUI_NATIVE "Build the native window" ON)
option(TELAR_GUI_SANITIZERS "Enable address and undefined behavior sanitizers" OFF)
# clangd, gui-lint and per-file incremental rebuilds need one compile command per source.
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
  set(telar_gui_batch_default 0)
else()
  set(telar_gui_batch_default 12)
endif()
set(TELAR_GUI_BATCH_SIZE ${telar_gui_batch_default} CACHE STRING "Sources compiled together in gui-quick; 0 compiles each one alone")

get_filename_component(TELAR_ROOT "../.." ABSOLUTE)
add_subdirectory("${TELAR_ROOT}/lib/config" "${CMAKE_CURRENT_BINARY_DIR}/telar-config")
add_subdirectory("${TELAR_ROOT}/lib/machines" "${CMAKE_CURRENT_BINARY_DIR}/telar-machines")
add_subdirectory("${TELAR_ROOT}/lib/shell" "${CMAKE_CURRENT_BINARY_DIR}/telar-shell")
add_subdirectory("${TELAR_ROOT}/lib/render" "${CMAKE_CURRENT_BINARY_DIR}/telar-render")
add_subdirectory("${TELAR_ROOT}/lib/ebnf" "${CMAKE_CURRENT_BINARY_DIR}/ebnf")
find_package(Python3 REQUIRED COMPONENTS Interpreter)
find_package(Threads REQUIRED)

file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(READ "${TELAR_ROOT}/lib/config/bootstrap.lua" TELAR_CONFIG_BOOTSTRAP)
configure_file(config/bootstrap.inc.in "${CMAKE_CURRENT_BINARY_DIR}/generated/gui_config_bootstrap.inc" @ONLY)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${TELAR_ROOT}/lib/config/bootstrap.lua")

include(cmake/fonts.cmake)

add_library(gui-core STATIC terminal/glyphs/curve_cache/box_curve.cpp platform/awake_clock/awake_clock.cpp platform/wall_clock/wall_clock.cpp)
# The session reads shared images, so their source links with it.
target_sources(gui-core PRIVATE
  application/host_effects/host_effects.cpp
  application/session/agents.cpp
  application/session/blocks.cpp
  application/session/commands.cpp
  application/session/copy_mode.cpp
  application/session/graphics.cpp
  application/session/history.cpp
  application/session/layout.cpp
  application/session/prompt.cpp
  application/session/session.cpp
  application/session/terminal.cpp
  application/sound_playback/sound_playback.cpp
  application/workspace_replica/workspace_replica.cpp
  platform/shared_image_source/shared_image_source.cpp)
telar_modules(gui-core)
# The implementation units of the terminal, fonts, graphics, presentation, layout and model
# domain interfaces.
target_sources(gui-core PRIVATE
  fonts/text_runs/text_runs.cpp
  graphics/pauses/pauses.cpp
  graphics/placeholder/placeholder.cpp
  graphics/texture_cache/texture_cache.cpp
  layout/geometry/geometry.cpp
  layout/snapshots/snapshots.cpp
  model/records/records.cpp
  model/replicas/replicas.cpp
  presentation/activity_order/activity_order.cpp
  presentation/application_mark/application_mark.cpp
  presentation/display_metrics/display_metrics.cpp
  presentation/form_field_geometry/form_field_geometry.cpp
  presentation/frame_pacer/frame_pacer.cpp
  presentation/history_filter_geometry/history_filter_geometry.cpp
  presentation/history_inspection/history_inspection.cpp
  presentation/history_inspection_geometry/history_inspection_geometry.cpp
  presentation/history_meta_geometry/history_meta_geometry.cpp
  presentation/history_pointer/history_pointer.cpp
  presentation/notification_center/notification_center.cpp
  presentation/notification_stack/notification_stack.cpp
  presentation/suggestion_geometry/suggestion_geometry.cpp
  presentation/suggestion_labels/suggestion_labels.cpp
  presentation/tab_drop/tab_drop.cpp
  terminal/font_grid/font_grid.cpp
  terminal/glyphs/curve_cache/curve_cache.cpp
  terminal/glyphs/glyphs.cpp
  terminal/row_cache/row_cache.cpp
  terminal/selection/selection.cpp)

# The implementation units of the input, prompt, components, config, platform, machines,
# attachments, history, text and remaining domain interfaces.
target_sources(gui-core PRIVATE
  attachments/catalog/catalog.cpp
  attachments/marker_input/marker_input.cpp
  components/builtin_content/builtin_content.cpp
  components/configuration/configuration.cpp
  config/generation/generation.cpp
  config/gui_query/gui_query.cpp
  config/plugin_effects/plugin_effects.cpp
  config/plugin_query/plugin_query.cpp
  core/json_writer/json_writer.cpp
  core/metrics/metrics.cpp
  core/unicode_scalar/unicode_scalar.cpp
  history/browser/browser.cpp
  input/child_mouse/child_mouse.cpp
  input/configuration/configuration.cpp
  input/copy_mode/copy_mode.cpp
  input/copy_pointer/copy_pointer.cpp
  input/key_encoder/key_encoder.cpp
  links/cell_links/cell_links.cpp
  links/link_hover/link_hover.cpp
  links/path_expansion/path_expansion.cpp
  machines/discovery/discovery.cpp
  machines/picker/picker.cpp
  machines/profile_store/profile_store.cpp
  palette/navigation_label/navigation_label.cpp
  paths/label/label.cpp
  peek/screen/screen.cpp
  platform/file_stamp/file_stamp.cpp
  platform/notification_commands/notification_commands.cpp
  platform/private_file_stamp/private_file_stamp.cpp
  platform/progress_cosine/progress_cosine.cpp
  platform/secure_random/secure_random.cpp
  prompt/completion/completion.cpp
  prompt/editor/editor.cpp
  prompt/editor/editor-text.cpp
  prompt/layout/layout.cpp
  prompt/line/line.cpp
  prompt/routing/routing.cpp
  suggestions/state/state.cpp
  text/bounded_editor/bounded_editor.cpp
  text/json_unsigned_integer/json_unsigned_integer.cpp
  text/notification_payload/notification_payload.cpp
  transport/runtime_link/runtime_link.cpp
)
target_link_libraries(gui-core PUBLIC telar::shell telar::render ebnf::ebnf)
target_include_directories(gui-core PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/generated" "${TELAR_ROOT}/lib/tbc/include")
target_link_libraries(gui-core PUBLIC telar::config telar::machines gui-harfbuzz)
target_compile_options(gui-core PUBLIC -Wall -Wextra -Wpedantic -ffp-contract=off)
set_source_files_properties(terminal/glyphs/curve_cache/box_curve.cpp PROPERTIES COMPILE_OPTIONS -ffp-contract=off)
# Compatibility target names for existing focused tests; their implementations
# now share the domain module provider and its compilation configuration.
add_library(gui-glyphs INTERFACE)
target_link_libraries(gui-glyphs INTERFACE gui-core)
add_library(gui-clock INTERFACE)
target_link_libraries(gui-clock INTERFACE gui-core)

add_library(gui-posix STATIC platform/clipboard_image_file.c platform/peer_identity/peer_identity.cpp platform/window_lease/window_lease.cpp platform/profile_file/profile_file.cpp  platform/stdio_socket/stdio_socket.cpp platform/managed_directory/managed_directory.cpp platform/process_group/process_group.cpp)
target_sources(gui-posix PRIVATE platform/clipboard_image_pipe/clipboard_image_pipe.cpp)
target_link_libraries(gui-posix PUBLIC gui-core Threads::Threads)
add_executable(telar-gui-command platform/surface_command_main.c)
target_compile_definitions(telar-gui-command PRIVATE "$<$<PLATFORM_ID:Linux>:_GNU_SOURCE>")
target_compile_options(telar-gui-command PRIVATE -Wall -Wextra -Wpedantic)

set(TELAR_GUI_LINT_JOBS 2 CACHE STRING "Parallel clang-tidy processes")
add_custom_target(gui-lint
  COMMAND "${CMAKE_COMMAND}"
    "-DGUI_BUILD_DIRECTORY=${CMAKE_CURRENT_BINARY_DIR}"
    "-DGUI_LINT_JOBS=${TELAR_GUI_LINT_JOBS}"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/lint.cmake"
  USES_TERMINAL
  VERBATIM)
add_dependencies(gui-lint gui-posix gui-glyphs telar-gui-command)

add_custom_target(gui-lifetime
  COMMAND "${CMAKE_COMMAND}"
    "-DGUI_BUILD_DIRECTORY=${CMAKE_CURRENT_BINARY_DIR}"
    "-DTBC_LINTER=${TBC_LINTER}"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/lifetime.cmake"
  USES_TERMINAL
  VERBATIM)
add_dependencies(gui-lifetime gui-posix gui-glyphs telar-gui-command)

add_custom_target(gui-interface-bodies
  COMMAND "${CMAKE_COMMAND}"
    "-DGUI_BUILD_DIRECTORY=${CMAKE_CURRENT_BINARY_DIR}"
    "-DTBC_LINTER=${TBC_LINTER}"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/interface_bodies.cmake"
  USES_TERMINAL
  VERBATIM)
add_dependencies(gui-interface-bodies gui-posix gui-glyphs telar-gui-command)

add_custom_target(gui-blank-lines
  COMMAND "${CMAKE_COMMAND}"
    "-DGUI_BUILD_DIRECTORY=${CMAKE_CURRENT_BINARY_DIR}"
    "-DTBC_LINTER=${TBC_LINTER}"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/blank_lines.cmake"
  USES_TERMINAL
  VERBATIM)
add_dependencies(gui-blank-lines gui-posix gui-glyphs telar-gui-command)

add_library(gui-config INTERFACE)
set(GHOSTTY_VT_ROOT "" CACHE PATH "Installed libghostty-vt prefix")
find_path(GHOSTTY_VT_INCLUDE_DIR ghostty/vt/unicode.h HINTS "${GHOSTTY_VT_ROOT}/include" REQUIRED)
find_library(GHOSTTY_VT_LIBRARY NAMES libghostty-vt.a HINTS "${GHOSTTY_VT_ROOT}/lib" REQUIRED)
add_library(gui-unicode UNKNOWN IMPORTED)
set_target_properties(gui-unicode PROPERTIES
  IMPORTED_LOCATION "${GHOSTTY_VT_LIBRARY}"
  INTERFACE_INCLUDE_DIRECTORIES "${GHOSTTY_VT_INCLUDE_DIR}")
target_link_libraries(gui-core PUBLIC gui-unicode)
target_link_libraries(gui-config INTERFACE gui-core gui-unicode)
target_include_directories(gui-config INTERFACE "${CMAKE_CURRENT_BINARY_DIR}/generated")

file(GENERATE
  OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/clangd/config/compile_flags.txt"
  CONTENT "-xc++\n-std=c++${CMAKE_CXX_STANDARD}\n-I$<JOIN:$<REMOVE_DUPLICATES:$<TARGET_PROPERTY:gui-config,INTERFACE_INCLUDE_DIRECTORIES>>,\n-I>\n-D$<JOIN:$<TARGET_PROPERTY:gui-config,INTERFACE_COMPILE_DEFINITIONS>,\n-D>\n")

add_custom_target(gui-editor)
add_library(gui-editor-context INTERFACE)
target_link_libraries(gui-editor-context INTERFACE gui-config)
file(GENERATE
  OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/clangd/domain/compile_flags.txt"
  CONTENT "-xc++\n-std=c++${CMAKE_CXX_STANDARD}\n-I$<JOIN:$<REMOVE_DUPLICATES:$<TARGET_PROPERTY:gui-editor-context,INTERFACE_INCLUDE_DIRECTORIES>>,\n-I>\n-D$<JOIN:$<TARGET_PROPERTY:gui-editor-context,INTERFACE_COMPILE_DEFINITIONS>,\n-D>\n")

include(CTest)
if(BUILD_TESTING)
  # Shared test fixtures are module interfaces. They import gui-core,
  # whose -ffp-contract=off they inherit like every other GUI importer.
  file(GLOB gui_test_fixtures CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/tests/*/*.cppm")
  list(REMOVE_ITEM gui_test_fixtures "${CMAKE_CURRENT_SOURCE_DIR}/tests/font_fixture/font_fixture.cppm")
  add_library(gui-test-fixtures STATIC)
  target_sources(gui-test-fixtures PUBLIC FILE_SET CXX_MODULES BASE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}" FILES ${gui_test_fixtures})
  target_link_libraries(gui-test-fixtures PUBLIC gui-core)
  set_target_properties(gui-test-fixtures PROPERTIES POSITION_INDEPENDENT_CODE ON)

  add_executable(gui-session-effects-test tests/session_effects_test.cpp)
  target_link_libraries(gui-session-effects-test PRIVATE gui-core gui-test-fixtures)
  add_test(NAME gui-session-effects COMMAND gui-session-effects-test)
  add_dependencies(gui-lint gui-session-effects-test)

  add_executable(gui-clipboard-image-pipe-test tests/clipboard_image_pipe_test.cpp tests/platform/clipboard_pipe_status.c)
  target_link_libraries(gui-clipboard-image-pipe-test PRIVATE gui-posix gui-test-fixtures)
  add_test(NAME gui-clipboard-image-pipe COMMAND gui-clipboard-image-pipe-test)
  set_tests_properties(gui-clipboard-image-pipe PROPERTIES TIMEOUT 20)
  add_dependencies(gui-lint gui-clipboard-image-pipe-test)

  add_executable(gui-attachment-capture-test tests/attachment_capture_test.cpp)
  target_link_libraries(gui-attachment-capture-test PRIVATE gui-core)
  add_test(NAME gui-attachment-capture COMMAND gui-attachment-capture-test)
  add_dependencies(gui-lint gui-attachment-capture-test)

  add_executable(gui-attachment-catalog-test tests/attachment_catalog_test.cpp)
  target_link_libraries(gui-attachment-catalog-test PRIVATE gui-core gui-test-fixtures)
  add_test(NAME gui-attachment-catalog COMMAND gui-attachment-catalog-test)
  add_dependencies(gui-lint gui-attachment-catalog-test)

  add_executable(gui-attachment-marker-test tests/attachment_marker_test.cpp)
  target_link_libraries(gui-attachment-marker-test PRIVATE gui-core)
  add_test(NAME gui-attachment-marker COMMAND gui-attachment-marker-test)
  add_dependencies(gui-lint gui-attachment-marker-test)

  add_executable(gui-attachment-layout-test tests/attachment_layout_test.cpp)
  target_link_libraries(gui-attachment-layout-test PRIVATE gui-core)
  add_test(NAME gui-attachment-layout COMMAND gui-attachment-layout-test)
  add_dependencies(gui-lint gui-attachment-layout-test)

  add_executable(gui-host-commands-test tests/host_commands_test.cpp)
  target_link_libraries(gui-host-commands-test PRIVATE gui-core)
  add_test(NAME gui-host-commands COMMAND gui-host-commands-test)
  add_dependencies(gui-lint gui-host-commands-test)

  add_executable(gui-agent-acknowledgement-test tests/agent_acknowledgement_test.cpp)
  target_link_libraries(gui-agent-acknowledgement-test PRIVATE gui-core gui-test-fixtures)
  add_test(NAME gui-agent-acknowledgement COMMAND gui-agent-acknowledgement-test)
  add_dependencies(gui-lint gui-agent-acknowledgement-test)

  add_executable(gui-display-metrics-test tests/display_metrics_test.cpp)
  target_link_libraries(gui-display-metrics-test PRIVATE gui-core)
  target_compile_options(gui-display-metrics-test PRIVATE -ffp-contract=off)
  add_test(NAME gui-display-metrics COMMAND gui-display-metrics-test)
  add_dependencies(gui-lint gui-display-metrics-test)

  add_executable(gui-agent-alerts-test tests/agent_alerts_test.cpp)
  target_link_libraries(gui-agent-alerts-test PRIVATE gui-core)
  add_test(NAME gui-agent-alerts COMMAND gui-agent-alerts-test)
  add_dependencies(gui-lint gui-agent-alerts-test)

  add_executable(gui-notification-center-test tests/notification_center_test.cpp)
  target_link_libraries(gui-notification-center-test PRIVATE gui-core)
  target_compile_options(gui-notification-center-test PRIVATE -ffp-contract=off)
  add_test(NAME gui-notification-center COMMAND gui-notification-center-test)
  add_dependencies(gui-lint gui-notification-center-test)

  add_executable(gui-notification-text-test tests/notification_text_test.cpp)
  target_link_libraries(gui-notification-text-test PRIVATE gui-core gui-unicode)
  add_test(NAME gui-notification-text COMMAND gui-notification-text-test)
  add_dependencies(gui-lint gui-notification-text-test)

  add_executable(gui-notification-stack-test tests/notification_stack_test.cpp)
  target_link_libraries(gui-notification-stack-test PRIVATE gui-core)
  target_compile_options(gui-notification-stack-test PRIVATE -ffp-contract=off)
  add_test(NAME gui-notification-stack COMMAND gui-notification-stack-test)
  add_dependencies(gui-lint gui-notification-stack-test)

  add_executable(gui-graphics-retention-test tests/graphics_retention_test.cpp)
  target_link_libraries(gui-graphics-retention-test PRIVATE gui-core)
  add_test(NAME gui-graphics-retention COMMAND gui-graphics-retention-test)
  add_dependencies(gui-lint gui-graphics-retention-test)
  add_executable(gui-image-residency-test tests/image_residency_test.cpp)
  target_link_libraries(gui-image-residency-test PRIVATE gui-core)
  add_test(NAME gui-image-residency COMMAND gui-image-residency-test)
  add_dependencies(gui-lint gui-image-residency-test)
  add_executable(gui-graphics-recovery-test tests/graphics_recovery_test.cpp)
  target_link_libraries(gui-graphics-recovery-test PRIVATE gui-core gui-test-fixtures)
  add_test(NAME gui-graphics-recovery COMMAND gui-graphics-recovery-test)
  add_dependencies(gui-lint gui-graphics-recovery-test)
  add_executable(gui-shared-image-test tests/shared_image_test.cpp)
  target_link_libraries(gui-shared-image-test PRIVATE gui-posix gui-test-fixtures)
  add_test(NAME gui-shared-image COMMAND gui-shared-image-test)
  add_dependencies(gui-lint gui-shared-image-test)

  add_executable(gui-session-notifications-test tests/session_notifications_test.cpp)
  target_link_libraries(gui-session-notifications-test PRIVATE gui-core gui-test-fixtures)
  add_test(NAME gui-session-notifications COMMAND gui-session-notifications-test)
  add_dependencies(gui-lint gui-session-notifications-test)

  add_executable(gui-notification-actions-test tests/notification_actions_test.cpp)
  target_link_libraries(gui-notification-actions-test PRIVATE gui-config)
  add_test(NAME gui-notification-actions COMMAND gui-notification-actions-test)
  add_dependencies(gui-lint gui-notification-actions-test)

  add_executable(gui-notification-effects-test tests/notification_effects_test.cpp)
  target_link_libraries(gui-notification-effects-test PRIVATE gui-core)
  add_test(NAME gui-notification-effects COMMAND gui-notification-effects-test)
  add_dependencies(gui-lint gui-notification-effects-test)

  add_executable(gui-pane-creation-test tests/pane_creation_test.cpp)
  target_link_libraries(gui-pane-creation-test PRIVATE gui-core gui-test-fixtures)
  add_test(NAME gui-pane-creation COMMAND gui-pane-creation-test)
  add_dependencies(gui-lint gui-pane-creation-test)
  add_executable(gui-command-tab-test tests/command_tab_test.cpp)
  target_link_libraries(gui-command-tab-test PRIVATE gui-config gui-test-fixtures)
  add_test(NAME gui-command-tab COMMAND gui-command-tab-test)
  add_dependencies(gui-lint gui-command-tab-test)
  add_executable(gui-binding-query-test tests/binding_query_test.cpp)
  target_link_libraries(gui-binding-query-test PRIVATE gui-config gui-test-fixtures)
  add_test(NAME gui-binding-query COMMAND gui-binding-query-test)
  add_dependencies(gui-lint gui-binding-query-test)
  add_executable(gui-theme-test tests/theme_test.cpp)
  target_link_libraries(gui-theme-test PRIVATE gui-config)
  add_test(NAME gui-theme COMMAND gui-theme-test)
  add_dependencies(gui-lint gui-theme-test)
  add_executable(gui-config-query-test tests/configuration_query_test.cpp)
  target_link_libraries(gui-config-query-test PRIVATE gui-config gui-test-fixtures)
  add_test(NAME gui-config-query COMMAND gui-config-query-test)
  add_dependencies(gui-lint gui-config-query-test)
  add_executable(gui-presentation-test tests/presentation_test.cpp)
  target_link_libraries(gui-presentation-test PRIVATE gui-core)
  add_test(NAME gui-presentation COMMAND gui-presentation-test)
  add_dependencies(gui-lint gui-presentation-test)
  add_executable(gui-text-fit-test tests/text_fit_test.cpp)
  target_link_libraries(gui-text-fit-test PRIVATE gui-core gui-unicode gui-test-fixtures)
  target_compile_options(gui-text-fit-test PRIVATE -ffp-contract=off)
  add_test(NAME gui-text-fit COMMAND gui-text-fit-test)
  add_dependencies(gui-lint gui-text-fit-test)
  add_executable(gui-font-grid-test tests/font_grid_test.cpp)
  target_link_libraries(gui-font-grid-test PRIVATE gui-core gui-test-fixtures)
  add_test(NAME gui-font-grid COMMAND gui-font-grid-test)
  add_dependencies(gui-lint gui-font-grid-test)
  add_executable(gui-core-test tests/core_test.cpp)
  target_link_libraries(gui-core-test PRIVATE gui-core gui-test-fixtures)
  add_test(NAME gui-core COMMAND gui-core-test)
  add_executable(gui-color-test tests/color_test.cpp)
  target_link_libraries(gui-color-test PRIVATE gui-core)
  add_test(NAME gui-color COMMAND gui-color-test)
  add_dependencies(gui-lint gui-color-test)
  add_executable(gui-screen-probe tools/screen_probe.cpp)
  target_link_libraries(gui-screen-probe PRIVATE gui-core)
  add_dependencies(gui-lint gui-screen-probe)
  add_executable(gui-glyph-ink-probe tools/glyph_ink_probe.cpp)
  target_link_libraries(gui-glyph-ink-probe PRIVATE gui-core)
  add_dependencies(gui-lint gui-glyph-ink-probe)
  add_executable(gui-awake-clock-test tests/awake_clock_test.cpp)
  target_link_libraries(gui-awake-clock-test PRIVATE gui-clock)
  add_test(NAME gui-awake-clock COMMAND gui-awake-clock-test)
  set_tests_properties(gui-awake-clock PROPERTIES TIMEOUT 30)
  add_dependencies(gui-lint gui-awake-clock-test)
  add_executable(gui-wall-clock-test tests/wall_clock_test.cpp)
  target_link_libraries(gui-wall-clock-test PRIVATE gui-clock)
  function(gui_add_wall_clock_test name zone offset)
    add_test(NAME "${name}" COMMAND "${CMAKE_COMMAND}" -E env "TZ=${zone}" $<TARGET_FILE:gui-wall-clock-test> "${offset}")
    set_tests_properties("${name}" PROPERTIES TIMEOUT 30)
  endfunction()
  gui_add_wall_clock_test(gui-wall-clock UTC0 0)
  gui_add_wall_clock_test(gui-wall-clock-nepal NPT-5:45 345)
  gui_add_wall_clock_test(gui-wall-clock-newfoundland NST3:30 -210)
  gui_add_wall_clock_test(gui-wall-clock-line-islands LINT-14 840)
  gui_add_wall_clock_test(gui-wall-clock-baker-island IDLW12 -720)
  add_dependencies(gui-lint gui-wall-clock-test)
  add_executable(gui-agent-replica-test tests/agent_replica_test.cpp)
  target_link_libraries(gui-agent-replica-test PRIVATE gui-core gui-test-fixtures)
  add_test(NAME gui-agent-replica COMMAND gui-agent-replica-test)
  set_tests_properties(gui-agent-replica PROPERTIES TIMEOUT 30)
  add_dependencies(gui-lint gui-agent-replica-test)
  add_executable(gui-tab-activity-test tests/tab_activity_test.cpp)
  target_link_libraries(gui-tab-activity-test PRIVATE gui-core gui-test-fixtures)
  target_compile_options(gui-tab-activity-test PRIVATE -ffp-contract=off)
  add_test(NAME gui-tab-activity COMMAND gui-tab-activity-test)
  add_dependencies(gui-lint gui-tab-activity-test)
  add_executable(gui-project-activity-test tests/project_activity_test.cpp)
  target_link_libraries(gui-project-activity-test PRIVATE gui-core gui-test-fixtures)
  add_test(NAME gui-project-activity COMMAND gui-project-activity-test)
  add_dependencies(gui-lint gui-project-activity-test)
  add_executable(gui-activity-test tests/activity_test.cpp)
  target_link_libraries(gui-activity-test PRIVATE gui-core gui-test-fixtures)
  add_test(NAME gui-activity COMMAND gui-activity-test)
  set_tests_properties(gui-activity PROPERTIES TIMEOUT 30)
  add_dependencies(gui-lint gui-activity-test)
  add_executable(gui-machine-chrome-test tests/machine_chrome_test.cpp)
  target_link_libraries(gui-machine-chrome-test PRIVATE gui-core)
  target_compile_options(gui-machine-chrome-test PRIVATE -ffp-contract=off)
  add_test(NAME gui-machine-chrome COMMAND gui-machine-chrome-test)
  add_dependencies(gui-lint gui-machine-chrome-test)
  add_executable(gui-session-test tests/session_test.cpp)
  target_link_libraries(gui-session-test PRIVATE gui-core gui-test-fixtures)
  add_test(NAME gui-session COMMAND gui-session-test)
  add_executable(gui-document-session-test tests/document_session_test.cpp)
  target_link_libraries(gui-document-session-test PRIVATE gui-core gui-test-fixtures)
  add_test(NAME gui-document-session COMMAND gui-document-session-test)
  add_executable(gui-scroll-test tests/scroll_test.cpp)
  target_link_libraries(gui-scroll-test PRIVATE gui-core gui-test-fixtures)
  add_test(NAME gui-scroll COMMAND gui-scroll-test)
  add_dependencies(gui-lint gui-scroll-test)
  add_executable(gui-host-metrics-test tests/host_metrics_test.cpp)
  target_link_libraries(gui-host-metrics-test PRIVATE gui-core gui-test-fixtures)
  add_test(NAME gui-host-metrics COMMAND gui-host-metrics-test)
  add_dependencies(gui-lint gui-host-metrics-test)
  add_executable(gui-palette-test tests/palette_test.cpp)
  target_link_libraries(gui-palette-test PRIVATE gui-core)
  target_compile_options(gui-palette-test PRIVATE -ffp-contract=off)
  add_test(NAME gui-palette COMMAND gui-palette-test)
  add_dependencies(gui-lint gui-palette-test)

  add_executable(gui-worktree-actions-test tests/worktree_actions_test.cpp)
  target_link_libraries(gui-worktree-actions-test PRIVATE gui-core gui-test-fixtures)
  add_test(NAME gui-worktree-actions COMMAND gui-worktree-actions-test)
  add_dependencies(gui-lint gui-worktree-actions-test)
  add_executable(gui-workspace-navigation-test tests/workspace_navigation_test.cpp)
  target_link_libraries(gui-workspace-navigation-test PRIVATE gui-core gui-test-fixtures)
  add_test(NAME gui-workspace-navigation COMMAND gui-workspace-navigation-test)
  add_dependencies(gui-lint gui-workspace-navigation-test)

  add_executable(gui-agent-peek-test tests/agent_peek_test.cpp)
  target_link_libraries(gui-agent-peek-test PRIVATE gui-core gui-test-fixtures)
  add_test(NAME gui-agent-peek COMMAND gui-agent-peek-test)
  add_dependencies(gui-lint gui-agent-peek-test)
  add_executable(gui-runtime-link-test tests/runtime_link_test.cpp)
  target_link_libraries(gui-runtime-link-test PRIVATE gui-core)
  add_test(NAME gui-runtime-link COMMAND gui-runtime-link-test)
  add_dependencies(gui-lint gui-runtime-link-test)
  add_executable(gui-runtime-handshake-test tests/runtime_handshake_test.cpp)
  target_link_libraries(gui-runtime-handshake-test PRIVATE gui-core)
  add_test(NAME gui-runtime-handshake COMMAND gui-runtime-handshake-test)
  add_dependencies(gui-lint gui-runtime-handshake-test)

  add_executable(gui-path-picker-session-test tests/path_picker_session_test.cpp)
  target_link_libraries(gui-path-picker-session-test PRIVATE gui-core gui-test-fixtures)
  add_test(NAME gui-path-picker-session COMMAND gui-path-picker-session-test)
  add_dependencies(gui-lint gui-path-picker-session-test)

  add_executable(gui-path-picker-test tests/path_picker_test.cpp)
  target_link_libraries(gui-path-picker-test PRIVATE gui-core gui-unicode)
  add_test(NAME gui-path-picker COMMAND gui-path-picker-test)
  add_dependencies(gui-lint gui-path-picker-test)

  add_executable(gui-suggestion-state-test tests/suggestion_state_test.cpp)
  target_link_libraries(gui-suggestion-state-test PRIVATE gui-core gui-unicode)
  add_test(NAME gui-suggestion-state COMMAND gui-suggestion-state-test)
  add_dependencies(gui-lint gui-suggestion-state-test)

  add_executable(gui-prompt-editor-test tests/prompt_editor_test.cpp)
  target_link_libraries(gui-prompt-editor-test PRIVATE gui-core)
  add_test(NAME gui-prompt-editor COMMAND gui-prompt-editor-test)
  add_dependencies(gui-lint gui-prompt-editor-test)

  add_executable(gui-prompt-session-test tests/prompt_session_test.cpp)
  target_link_libraries(gui-prompt-session-test PRIVATE gui-core gui-test-fixtures)
  add_test(NAME gui-prompt-session COMMAND gui-prompt-session-test)
  add_dependencies(gui-lint gui-prompt-session-test)

  add_executable(gui-suggestion-session-test tests/suggestion_session_test.cpp)
  target_link_libraries(gui-suggestion-session-test PRIVATE gui-core gui-test-fixtures)
  add_test(NAME gui-suggestion-session COMMAND gui-suggestion-session-test)
  add_dependencies(gui-lint gui-suggestion-session-test)

  add_executable(gui-machine-profiles-test tests/machine_profiles_test.cpp)
  target_link_libraries(gui-machine-profiles-test PRIVATE gui-core)
  add_test(NAME gui-machine-profiles COMMAND gui-machine-profiles-test)
  add_dependencies(gui-lint gui-machine-profiles-test)

  add_executable(gui-machine-opening-test tests/machine_opening_test.cpp)
  target_link_libraries(gui-machine-opening-test PRIVATE gui-core)
  add_test(NAME gui-machine-opening COMMAND gui-machine-opening-test)
  add_dependencies(gui-lint gui-machine-opening-test)

  add_executable(gui-machine-runtime-location-test tests/machine_runtime_location_test.cpp)
  target_link_libraries(gui-machine-runtime-location-test PRIVATE gui-core)
  add_test(NAME gui-machine-runtime-location COMMAND gui-machine-runtime-location-test)
  add_dependencies(gui-lint gui-machine-runtime-location-test)

  add_executable(gui-machines-test tests/machines_test.cpp)
  target_link_libraries(gui-machines-test PRIVATE gui-core)
  add_test(NAME gui-machines COMMAND gui-machines-test)
  add_dependencies(gui-lint gui-machines-test)
  add_executable(gui-json-integer-test tests/json_integer_test.cpp)
  target_link_libraries(gui-json-integer-test PRIVATE gui-core)
  add_test(NAME gui-json-integer COMMAND gui-json-integer-test)
  add_dependencies(gui-lint gui-json-integer-test)

  add_executable(gui-machine-remote-test tests/machine_remote_test.cpp)
  target_link_libraries(gui-machine-remote-test PRIVATE gui-core)
  add_test(NAME gui-machine-remote COMMAND gui-machine-remote-test)
  add_dependencies(gui-lint gui-machine-remote-test)

  add_executable(gui-machine-profile-store-test tests/machine_profile_store_test.cpp)
  target_link_libraries(gui-machine-profile-store-test PRIVATE gui-core)
  add_test(NAME gui-machine-profile-store COMMAND gui-machine-profile-store-test)
  add_dependencies(gui-lint gui-machine-profile-store-test)

  add_executable(gui-machine-profile-file-test tests/machine_profile_file_test.cpp)
  target_link_libraries(gui-machine-profile-file-test PRIVATE gui-posix Threads::Threads)
  add_test(NAME gui-machine-profile-file COMMAND gui-machine-profile-file-test)
  set_tests_properties(gui-machine-profile-file PROPERTIES TIMEOUT 30)
  add_dependencies(gui-lint gui-machine-profile-file-test)

  add_executable(gui-machine-presentation-test tests/machine_presentation_test.cpp)
  target_link_libraries(gui-machine-presentation-test PRIVATE gui-core gui-test-fixtures)
  add_test(NAME gui-machine-presentation COMMAND gui-machine-presentation-test)
  add_dependencies(gui-lint gui-machine-presentation-test)

  add_executable(gui-history-test tests/history_test.cpp)
  target_link_libraries(gui-history-test PRIVATE gui-core)
  add_test(NAME gui-history COMMAND gui-history-test)
  add_executable(gui-history-card-test tests/history_card_test.cpp)
  target_link_libraries(gui-history-card-test PRIVATE gui-core gui-unicode gui-test-fixtures)
  add_test(NAME gui-history-card COMMAND gui-history-card-test)
  set_tests_properties(gui-history-card PROPERTIES TIMEOUT 30)
  add_dependencies(gui-lint gui-history-card-test)
  add_executable(gui-editor-test tests/editor_test.cpp)
  target_link_libraries(gui-editor-test PRIVATE gui-core gui-unicode gui-test-fixtures)
  add_test(NAME gui-editor COMMAND gui-editor-test)
  add_dependencies(gui-lint gui-editor-test)
  add_executable(gui-input-test tests/input_test.cpp)
  target_link_libraries(gui-input-test PRIVATE gui-core)
  add_test(NAME gui-input COMMAND gui-input-test)
  add_executable(gui-key-encoder-test tests/key_encoder_test.cpp)
  target_link_libraries(gui-key-encoder-test PRIVATE gui-core)
  add_test(NAME gui-key-encoder COMMAND gui-key-encoder-test)
  add_dependencies(gui-lint gui-key-encoder-test)
  add_executable(gui-copy-mode-test tests/copy_mode_test.cpp)
  target_link_libraries(gui-copy-mode-test PRIVATE gui-core gui-test-fixtures)
  add_test(NAME gui-copy-mode COMMAND gui-copy-mode-test)
  set_tests_properties(gui-copy-mode PROPERTIES TIMEOUT 30)
  add_dependencies(gui-lint gui-copy-mode-test)
  add_executable(gui-directory-completion-test tests/directory_completion_test.cpp)
  target_link_libraries(gui-directory-completion-test PRIVATE gui-core)
  add_test(NAME gui-directory-completion COMMAND gui-directory-completion-test)
  set_tests_properties(gui-directory-completion PROPERTIES TIMEOUT 30)
  add_dependencies(gui-lint gui-directory-completion-test)
  add_executable(gui-links-test tests/links_test.cpp)
  target_link_libraries(gui-links-test PRIVATE gui-core gui-test-fixtures)
  add_test(NAME gui-links COMMAND gui-links-test)
  set_tests_properties(gui-links PROPERTIES TIMEOUT 30)
  add_dependencies(gui-lint gui-links-test)
  add_executable(gui-file-links-test tests/file_links_test.cpp)
  target_link_libraries(gui-file-links-test PRIVATE gui-core)
  add_test(NAME gui-file-links COMMAND gui-file-links-test)
  set_tests_properties(gui-file-links PROPERTIES TIMEOUT 30)
  add_dependencies(gui-lint gui-file-links-test)
  add_executable(gui-editor-session-test tests/editor_session_test.cpp)
  target_link_libraries(gui-editor-session-test PRIVATE gui-core gui-test-fixtures)
  add_test(NAME gui-editor-session COMMAND gui-editor-session-test)
  set_tests_properties(gui-editor-session PROPERTIES TIMEOUT 30)
  add_dependencies(gui-lint gui-editor-session-test)
  add_executable(gui-link-interaction-test tests/link_interaction_test.cpp)
  target_link_libraries(gui-link-interaction-test PRIVATE gui-core gui-test-fixtures)
  add_test(NAME gui-link-interaction COMMAND gui-link-interaction-test)
  set_tests_properties(gui-link-interaction PROPERTIES TIMEOUT 30)
  add_dependencies(gui-lint gui-link-interaction-test)
  add_executable(gui-child-mouse-test tests/child_mouse_test.cpp)
  target_link_libraries(gui-child-mouse-test PRIVATE gui-core)
  add_test(NAME gui-child-mouse COMMAND gui-child-mouse-test)
  set_tests_properties(gui-child-mouse PROPERTIES TIMEOUT 30)
  add_dependencies(gui-lint gui-child-mouse-test)
  add_executable(gui-cell-glyphs-test tests/cell_glyphs_test.cpp)
  target_link_libraries(gui-cell-glyphs-test PRIVATE gui-core gui-test-fixtures)
  add_test(NAME gui-cell-glyphs COMMAND gui-cell-glyphs-test)
  add_dependencies(gui-lint gui-cell-glyphs-test)
  add_executable(gui-layout-test tests/layout_test.cpp)
  target_link_libraries(gui-layout-test PRIVATE gui-core)
  add_test(NAME gui-layout COMMAND gui-layout-test)
  add_executable(gui-graphics-test tests/graphics_test.cpp)
  target_link_libraries(gui-graphics-test PRIVATE gui-core gui-test-fixtures)
  add_test(NAME gui-graphics COMMAND gui-graphics-test)
  add_executable(gui-config-test tests/configuration_test.cpp)
  target_link_libraries(gui-config-test PRIVATE gui-config)
  add_test(NAME gui-config COMMAND gui-config-test)
  add_executable(gui-component-config-test tests/component_configuration_test.cpp)
  target_link_libraries(gui-component-config-test PRIVATE gui-config)
  target_compile_definitions(gui-component-config-test PRIVATE TELAR_GUI_EXAMPLES_DIR="${TELAR_ROOT}/docs/examples")
  add_test(NAME gui-component-config COMMAND gui-component-config-test)
  set_tests_properties(gui-component-config PROPERTIES TIMEOUT 30)
  add_dependencies(gui-lint gui-component-config-test)

  add_executable(gui-pick-items-test tests/pick_items_test.cpp)
  target_link_libraries(gui-pick-items-test PRIVATE gui-config)
  add_test(NAME gui-pick-items COMMAND gui-pick-items-test)
  set_tests_properties(gui-pick-items PROPERTIES TIMEOUT 30)
  add_dependencies(gui-lint gui-pick-items-test)
  add_executable(gui-platform-test tests/platform_test.cpp)
  target_link_libraries(gui-platform-test PRIVATE gui-posix)
  add_test(NAME gui-platform COMMAND gui-platform-test)
  set_tests_properties(gui-core gui-session gui-history gui-input gui-key-encoder gui-layout gui-graphics gui-config gui-platform PROPERTIES TIMEOUT 30)
  add_dependencies(gui-lint gui-core-test gui-session-test gui-history-test gui-input-test gui-layout-test gui-graphics-test gui-config-test gui-platform-test)
endif()

if(TELAR_GUI_NATIVE)
  add_library(gui-fonts STATIC fonts/face/face.cpp fonts/face/ligature_coverage.cpp fonts/font_requests/font_requests.cpp fonts/row_text_layout/row_text_layout.cpp)
  target_link_libraries(gui-fonts PUBLIC gui-core gui-harfbuzz)
  target_link_libraries(gui-editor-context INTERFACE gui-fonts)
  target_compile_options(gui-fonts PRIVATE -ffp-contract=off)
  add_dependencies(gui-lint gui-fonts)

  if(BUILD_TESTING)
    add_library(gui-test-font-fixture STATIC)
    target_sources(gui-test-font-fixture PUBLIC FILE_SET CXX_MODULES BASE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}" FILES tests/font_fixture/font_fixture.cppm)
    target_link_libraries(gui-test-font-fixture PUBLIC gui-fonts gui-test-fixtures)
    add_executable(gui-font-cascade-test tests/font_cascade_test.cpp)
    target_link_libraries(gui-font-cascade-test PRIVATE gui-fonts gui-unicode gui-test-font-fixture)
    target_compile_options(gui-font-cascade-test PRIVATE -ffp-contract=off)
    add_test(NAME gui-font-cascade COMMAND gui-font-cascade-test "${TELAR_ROOT}/assets")
    add_dependencies(gui-lint gui-font-cascade-test)
    add_executable(gui-row-text-test tests/row_text_test.cpp)
    target_link_libraries(gui-row-text-test PRIVATE gui-fonts gui-unicode gui-test-font-fixture)
    target_compile_options(gui-row-text-test PRIVATE -ffp-contract=off)
    add_test(NAME gui-row-text COMMAND gui-row-text-test "${TELAR_ROOT}/assets")
    add_dependencies(gui-lint gui-row-text-test)
    add_executable(gui-font-coverage-probe tools/font_coverage_probe.cpp)
    target_link_libraries(gui-font-coverage-probe PRIVATE gui-fonts)
    add_dependencies(gui-lint gui-font-coverage-probe)
  endif()

  include(cmake/qt.cmake)
  find_package(Qt6 ${TELAR_QT_VERSION} EXACT REQUIRED COMPONENTS Gui Qml Quick QuickControls2 Network Concurrent ShaderTools Svg
    PATHS "${TELAR_GUI_QT_PREFIX}/lib/cmake/Qt6" NO_DEFAULT_PATH)
  if(NOT TARGET Qt6::GuiPrivate)
    find_package(Qt6GuiPrivate ${TELAR_QT_VERSION} EXACT REQUIRED CONFIG
      PATHS "${TELAR_GUI_QT_PREFIX}/lib/cmake/Qt6GuiPrivate" NO_DEFAULT_PATH)
  endif()
  qt_standard_project_setup(REQUIRES 6.7)
  if(BUILD_TESTING)
    add_executable(gui-display-probe tools/display_probe.cpp)
    target_link_libraries(gui-display-probe PRIVATE Qt6::Gui)
  endif()
  add_library(gui-surface-command STATIC ui/components/surface_command.cpp)
  target_link_libraries(gui-surface-command PUBLIC gui-posix Qt6::Core)
  add_dependencies(gui-surface-command telar-gui-command)
  add_dependencies(gui-lint gui-surface-command)
  if(BUILD_TESTING)
    add_executable(gui-surface-command-test tests/surface_command_test.cpp)
    target_link_libraries(gui-surface-command-test PRIVATE gui-surface-command)
    add_test(NAME gui-surface-command COMMAND gui-surface-command-test)
    set_tests_properties(gui-surface-command PROPERTIES TIMEOUT 30)
    add_dependencies(gui-lint gui-surface-command-test)
  endif()

  if(BUILD_TESTING)
    add_executable(gui-native-pointer-events-test tests/native_pointer_events_test.cpp ui/input/native_pointer_events.cpp)
    target_link_libraries(gui-native-pointer-events-test PRIVATE gui-core Qt6::Gui Qt6::GuiPrivate)
    add_test(NAME gui-native-pointer-events COMMAND gui-native-pointer-events-test)
    set_tests_properties(gui-native-pointer-events PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-native-pointer-events-test)
  endif()

  add_library(gui-machine-profiles STATIC ui/machines/machine_profiles_source.cpp ui/machines/machine_profiles_source.hpp)
  target_link_libraries(gui-machine-profiles PUBLIC gui-posix Qt6::Concurrent)
  add_dependencies(gui-lint gui-machine-profiles)
  if(Qt6_VERSION VERSION_GREATER_EQUAL 6.8)
    qt_policy(SET QTP0004 NEW)
  endif()

  add_library(gui-platform STATIC platform/login_shell/host_name.cpp)
  target_link_libraries(gui-platform PUBLIC gui-core gui-posix Qt6::Gui PRIVATE Qt6::Quick)
  if(BUILD_TESTING)
    add_executable(gui-background-blur-radius-test tests/background_blur_radius_test.cpp)
    target_link_libraries(gui-background-blur-radius-test PRIVATE gui-core)
    add_test(NAME gui-background-blur-radius COMMAND gui-background-blur-radius-test)
    add_dependencies(gui-lint gui-background-blur-radius-test)
  endif()
  if(APPLE)
    if(NOT DEFINED CMAKE_OBJCXX_COMPILER AND "$ENV{OBJCXX}" STREQUAL "" AND CMAKE_CXX_COMPILER_ID MATCHES "Clang")
      set(CMAKE_OBJCXX_COMPILER "${CMAKE_CXX_COMPILER}")
    endif()

    enable_language(OBJCXX)
    if(NOT DEFINED CMAKE_OBJC_COMPILER AND "$ENV{OBJC}" STREQUAL "" AND CMAKE_CXX_COMPILER_ID MATCHES "Clang")
      set(CMAKE_OBJC_COMPILER "${CMAKE_CXX_COMPILER}")
    endif()

    enable_language(OBJC)
    set(CMAKE_OBJCXX_STANDARD 23)
    set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
    include(CheckOBJCXXCompilerFlag)
    check_objcxx_compiler_flag(-fno-objc-msgsend-class-selector-stubs TELAR_GUI_HAS_OBJC_CLASS_STUB_CONTROL)
    target_sources(gui-platform PRIVATE platform/macos/window.mm platform/macos/blur_symbols.m platform/macos/text_input.mm platform/macos/scroll_event.mm platform/macos/clipboard_image_source.mm)
    add_executable(gui-native-scroll-input-test tests/native_scroll_input_test.mm)
    target_link_libraries(gui-native-scroll-input-test PRIVATE gui-platform gui-core Qt6::Gui)
    target_compile_options(gui-native-scroll-input-test PRIVATE -fobjc-arc)
    if(TELAR_GUI_HAS_OBJC_CLASS_STUB_CONTROL)
      target_compile_options(gui-native-scroll-input-test PRIVATE -fno-objc-msgsend-class-selector-stubs)
    endif()
    add_test(NAME gui-native-scroll-input COMMAND gui-native-scroll-input-test)
    set_tests_properties(gui-native-scroll-input PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=cocoa" TIMEOUT 30)
    add_dependencies(gui-lint gui-native-scroll-input-test)
    add_executable(gui-native-window-appearance-test tests/native_window_appearance_test.mm)
    target_link_libraries(gui-native-window-appearance-test PRIVATE gui-platform gui-core Qt6::Quick)
    target_compile_options(gui-native-window-appearance-test PRIVATE -fobjc-arc)
    if(TELAR_GUI_HAS_OBJC_CLASS_STUB_CONTROL)
      target_compile_options(gui-native-window-appearance-test PRIVATE -fno-objc-msgsend-class-selector-stubs)
    endif()
    add_test(NAME gui-native-window-appearance COMMAND gui-native-window-appearance-test)
    set_tests_properties(gui-native-window-appearance PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=cocoa" TIMEOUT 30)
    add_dependencies(gui-lint gui-native-window-appearance-test)
    add_executable(gui-native-window-update-test tests/native_window_update_test.cpp)
    target_link_libraries(gui-native-window-update-test PRIVATE gui-platform Qt6::Quick Qt6::GuiPrivate)
    add_test(NAME gui-native-window-update COMMAND gui-native-window-update-test)
    set_tests_properties(gui-native-window-update PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=cocoa" TIMEOUT 30)
    add_dependencies(gui-lint gui-native-window-update-test)
    target_sources(gui-platform PRIVATE platform/macos/font.mm platform/macos/glyph_rasterizer.mm fonts/glyph_rasterizer/glyph_rasterizer.cpp)
    target_sources(gui-platform PRIVATE platform/macos/optical_text.mm)
    target_link_libraries(gui-platform PRIVATE Qt6::GuiPrivate)
    target_compile_options(gui-platform PRIVATE "$<$<COMPILE_LANGUAGE:OBJC,OBJCXX>:-fobjc-arc>")
    if(TELAR_GUI_HAS_OBJC_CLASS_STUB_CONTROL)
      target_compile_options(gui-platform PRIVATE "$<$<COMPILE_LANGUAGE:OBJC,OBJCXX>:-fno-objc-msgsend-class-selector-stubs>")
    endif()

    target_link_libraries(gui-platform PRIVATE "-framework AppKit" "-framework CoreText" "-framework CoreGraphics" "-framework ImageIO")
    if(BUILD_TESTING)
      add_executable(gui-clipboard-image-source-test tests/clipboard_image_source_test.mm)
      target_link_libraries(gui-clipboard-image-source-test PRIVATE gui-platform)
      target_compile_options(gui-clipboard-image-source-test PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
      if(TELAR_GUI_HAS_OBJC_CLASS_STUB_CONTROL)
        target_compile_options(gui-clipboard-image-source-test PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fno-objc-msgsend-class-selector-stubs>")
      endif()
      if(TELAR_SANITIZERS)
        set_property(SOURCE platform/macos/clipboard_image_source.mm APPEND PROPERTY COMPILE_OPTIONS -fsanitize=address,undefined -fno-omit-frame-pointer)
        target_compile_options(gui-clipboard-image-source-test PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fsanitize=address,undefined;-fno-omit-frame-pointer>")
      endif()
      add_test(NAME gui-clipboard-image-source COMMAND gui-clipboard-image-source-test)
      set_tests_properties(gui-clipboard-image-source PROPERTIES TIMEOUT 30)
      add_dependencies(gui-lint gui-clipboard-image-source-test)
    endif()

  elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    find_package(Fontconfig REQUIRED)
    find_package(Qt6 ${TELAR_QT_VERSION} EXACT REQUIRED COMPONENTS WaylandClient
      PATHS "${TELAR_GUI_QT_PREFIX}/lib/cmake/Qt6" NO_DEFAULT_PATH)
    if(NOT TARGET Qt6::WaylandClientPrivate)
      find_package(Qt6WaylandClientPrivate ${TELAR_QT_VERSION} EXACT REQUIRED CONFIG
        PATHS "${TELAR_GUI_QT_PREFIX}/lib/cmake/Qt6WaylandClientPrivate" NO_DEFAULT_PATH)
    endif()
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(GUI_WAYLAND_CLIENT REQUIRED IMPORTED_TARGET wayland-client)
    pkg_check_modules(GUI_XCB REQUIRED IMPORTED_TARGET xcb)
    find_program(GUI_WAYLAND_SCANNER wayland-scanner REQUIRED)
    set(GUI_BACKGROUND_EFFECT_XML "${CMAKE_CURRENT_SOURCE_DIR}/platform/linux/protocols/ext-background-effect-v1.xml")
    set(GUI_BACKGROUND_EFFECT_DIR "${CMAKE_CURRENT_BINARY_DIR}/gui-wayland")
    set(GUI_BACKGROUND_EFFECT_HEADER "${GUI_BACKGROUND_EFFECT_DIR}/ext-background-effect-v1-client-protocol.h")
    set(GUI_BACKGROUND_EFFECT_SERVER_HEADER "${GUI_BACKGROUND_EFFECT_DIR}/ext-background-effect-v1-server-protocol.h")
    set(GUI_BACKGROUND_EFFECT_CODE "${GUI_BACKGROUND_EFFECT_DIR}/ext-background-effect-v1-protocol.c")
    add_custom_command(OUTPUT "${GUI_BACKGROUND_EFFECT_HEADER}" "${GUI_BACKGROUND_EFFECT_CODE}" "${GUI_BACKGROUND_EFFECT_SERVER_HEADER}"
      COMMAND "${CMAKE_COMMAND}" -E make_directory "${GUI_BACKGROUND_EFFECT_DIR}"
      COMMAND "${GUI_WAYLAND_SCANNER}" client-header "${GUI_BACKGROUND_EFFECT_XML}" "${GUI_BACKGROUND_EFFECT_HEADER}"
      COMMAND "${GUI_WAYLAND_SCANNER}" server-header "${GUI_BACKGROUND_EFFECT_XML}" "${GUI_BACKGROUND_EFFECT_SERVER_HEADER}"
      COMMAND "${GUI_WAYLAND_SCANNER}" private-code "${GUI_BACKGROUND_EFFECT_XML}" "${GUI_BACKGROUND_EFFECT_CODE}"
      DEPENDS "${GUI_BACKGROUND_EFFECT_XML}" VERBATIM)
    target_sources(gui-platform PRIVATE platform/background_effect/background_effect.cpp
      platform/linux/background_effect.c "${GUI_BACKGROUND_EFFECT_HEADER}" "${GUI_BACKGROUND_EFFECT_CODE}")
    target_include_directories(gui-platform PRIVATE "${GUI_BACKGROUND_EFFECT_DIR}")
    target_link_libraries(gui-platform PRIVATE Qt6::WaylandClientPrivate PkgConfig::GUI_WAYLAND_CLIENT PkgConfig::GUI_XCB)
    target_link_libraries(gui-platform PRIVATE Fontconfig::Fontconfig)
    target_sources(gui-platform PRIVATE platform/linux/font.c)
    target_sources(gui-platform PRIVATE platform/linux/window.cpp platform/linux/clipboard_image_source.cpp platform/linux/clipboard_image_monitor.cpp platform/linux/xcb_clipboard_image_monitor.cpp platform/linux/wayland_clipboard_image_monitor.cpp)
    target_sources(gui-platform PRIVATE ui/scene/optical_text_fallback.cpp)
    if(BUILD_TESTING)
      pkg_check_modules(GUI_WAYLAND_SERVER REQUIRED IMPORTED_TARGET wayland-server)
      find_package(Qt6 ${TELAR_QT_VERSION} EXACT REQUIRED COMPONENTS WaylandCompositor
        PATHS "${TELAR_GUI_QT_PREFIX}/lib/cmake/Qt6" NO_DEFAULT_PATH)
      if(NOT TARGET Qt6::WaylandCompositorPrivate)
        find_package(Qt6WaylandCompositorPrivate ${TELAR_QT_VERSION} EXACT REQUIRED CONFIG
          PATHS "${TELAR_GUI_QT_PREFIX}/lib/cmake/Qt6WaylandCompositorPrivate" NO_DEFAULT_PATH)
      endif()
      qt_add_executable(gui-background-effect-server tools/background_effect_server.cpp)
      qt_generate_wayland_protocol_server_sources(gui-background-effect-server FILES "${GUI_BACKGROUND_EFFECT_XML}")
      target_link_libraries(gui-background-effect-server PRIVATE gui-core Qt6::WaylandCompositorPrivate PkgConfig::GUI_WAYLAND_SERVER)
      set_target_properties(gui-background-effect-server PROPERTIES QT_QML_MODULE_NO_IMPORT_SCAN TRUE)
      qt_add_executable(gui-background-effect-probe tools/background_effect_probe.cpp)
      target_link_libraries(gui-background-effect-probe PRIVATE gui-platform Qt6::Gui)
      set_target_properties(gui-background-effect-probe PROPERTIES QT_QML_MODULE_NO_IMPORT_SCAN TRUE)
      add_dependencies(gui-lint gui-background-effect-server gui-background-effect-probe)
      add_executable(gui-clipboard-wayland-lifecycle-server tools/clipboard_wayland_lifecycle_server.c)
      target_link_libraries(gui-clipboard-wayland-lifecycle-server PRIVATE PkgConfig::GUI_WAYLAND_SERVER)
      add_executable(gui-clipboard-wayland-lifecycle-probe tools/clipboard_wayland_lifecycle_probe.cpp)
      target_link_libraries(gui-clipboard-wayland-lifecycle-probe PRIVATE gui-platform Qt6::Core)
      add_dependencies(gui-lint gui-clipboard-wayland-lifecycle-server gui-clipboard-wayland-lifecycle-probe)
      qt_add_executable(gui-clipboard-wayland-provider tools/clipboard_wayland_provider.cpp)
      target_link_libraries(gui-clipboard-wayland-provider PRIVATE Qt6::Quick)
      qt_add_executable(gui-clipboard-wayland-probe tools/clipboard_wayland_probe.cpp)
      target_link_libraries(gui-clipboard-wayland-probe PRIVATE gui-clipboard-images Qt6::Quick)
      qt_add_executable(gui-clipboard-wayland-owned-probe tools/clipboard_wayland_owned_probe.cpp)
      target_link_libraries(gui-clipboard-wayland-owned-probe PRIVATE gui-clipboard-images Qt6::Quick PkgConfig::GUI_WAYLAND_CLIENT)
      add_dependencies(gui-lint gui-clipboard-wayland-owned-probe)
      target_include_directories(gui-clipboard-wayland-probe PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
      set_target_properties(gui-clipboard-wayland-provider gui-clipboard-wayland-probe PROPERTIES QT_QML_MODULE_NO_IMPORT_SCAN TRUE)
      add_dependencies(gui-lint gui-clipboard-wayland-provider gui-clipboard-wayland-probe)
    endif()
  else()
    message(FATAL_ERROR "The GUI supports macOS and Linux")
  endif()

  add_library(gui-keyboard STATIC ui/terminal/terminal_input.cpp)
  target_link_libraries(gui-keyboard PUBLIC gui-core Qt6::Gui)

  add_library(gui-clipboard-images STATIC ui/attachments/attachment_preview.cpp ui/attachments/attachment_preview.hpp ui/attachments/clipboard_images.cpp ui/attachments/clipboard_images.hpp)
  target_link_libraries(gui-clipboard-images PUBLIC gui-platform Qt6::Concurrent)
  add_dependencies(gui-lint gui-clipboard-images)

  qt_add_library(gui-quick STATIC)
  target_link_libraries(gui-quick PRIVATE Qt6::GuiPrivate)
  target_sources(gui-quick PRIVATE ui/terminal/window_images.cpp ui/terminal/image_resource.cpp)
  target_link_libraries(gui-quick PUBLIC gui-clipboard-images)
  set_source_files_properties(ui/attachments/attachment_preview.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  if(BUILD_TESTING)
    add_executable(gui-attachment-preview-test tests/attachment_preview_test.cpp ui/attachments/attachment_preview.cpp)
    target_include_directories(gui-attachment-preview-test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    target_link_libraries(gui-attachment-preview-test PRIVATE gui-core Qt6::Gui)
    add_test(NAME gui-attachment-preview COMMAND gui-attachment-preview-test)
    set_tests_properties(gui-attachment-preview PROPERTIES TIMEOUT 30)
    add_dependencies(gui-lint gui-attachment-preview-test)
  endif()

  target_sources(gui-quick PRIVATE ui/terminal/terminal_scene.cpp ui/terminal/terminal_scene.hpp)
  target_sources(gui-quick PRIVATE ui/scene/text_scene.cpp)
  target_sources(gui-quick PRIVATE ui/fonts/font_source.cpp ui/fonts/font_resolver.cpp)
  target_sources(gui-quick PRIVATE ui/fonts/bundled_fonts.cpp ui/fonts/terminal_font.cpp platform/runtime_endpoint/runtime_endpoint.cpp platform/login_shell/login_shell.cpp)
  target_link_libraries(gui-quick PUBLIC gui-core gui-config gui-platform gui-keyboard gui-fonts gui-machine-profiles Qt6::Quick Qt6::QuickControls2 Qt6::Network Qt6::Concurrent)
  # Most of a gui-quick compilation parses the same Qt headers again; the ones
  # that at least two in five Qt adapters include are parsed once per build.
  option(TELAR_GUI_PRECOMPILED_HEADERS "Precompile the Qt headers shared by gui-quick sources" ON)
  if(TELAR_GUI_PRECOMPILED_HEADERS)
    target_precompile_headers(gui-quick PRIVATE
      <QByteArray> <QColor> <QDir> <QFont> <QFutureWatcher> <QHash> <QIODevice> <QImage>
      <QKeyEvent> <QList> <QMetaObject> <QMouseEvent> <QObject> <QPointF> <QPointer>
      <QQuickItem> <QQuickWindow> <QRectF> <QSizeF> <QString> <QStringList> <QThread>
      <QTimer> <QVariant> <QVariantMap> <QWindow> <QtQml/qqmlregistration.h>)
    # Module units import std; a prefix with the textual standard library would
    # declare its names twice.
    get_target_property(gui_quick_sources gui-quick SOURCES)
    list(FILTER gui_quick_sources EXCLUDE REGEX "^ui/")
    set_source_files_properties(${gui_quick_sources} PROPERTIES SKIP_PRECOMPILE_HEADERS ON)
  endif()
  set(TELAR_GUI_LINK_HOST_HEADER "" CACHE FILEPATH "Header selecting a compile-time external link host")
  if(TELAR_GUI_LINK_HOST_HEADER)
    get_filename_component(gui_link_host_header "${TELAR_GUI_LINK_HOST_HEADER}" ABSOLUTE)
    if(NOT EXISTS "${gui_link_host_header}")
      message(FATAL_ERROR "TELAR_GUI_LINK_HOST_HEADER does not exist: ${gui_link_host_header}")
    endif()

    target_compile_options(gui-quick PUBLIC "$<$<COMPILE_LANGUAGE:CXX>:-include>" "$<$<COMPILE_LANGUAGE:CXX>:${gui_link_host_header}>")
    target_compile_definitions(gui-quick PUBLIC TELAR_GUI_CUSTOM_LINK_HOST=1)
  endif()

  target_sources(gui-quick PRIVATE ui/attachments/attachment_controller.cpp ui/plugins/plugin_controller.cpp ui/prompt/prompt_controller.cpp)
  target_sources(gui-quick PRIVATE ui/components/component_controller.cpp ui/components/pick_controller.cpp ui/components/element_controller.cpp ui/components/element_slots.cpp ui/components/element_slots.hpp)
  target_link_libraries(gui-quick PRIVATE gui-surface-command Qt6::Svg)
  target_sources(gui-quick PRIVATE ui/history/history_controller.cpp ui/history/history_controller.hpp ui/history/history_pointer.cpp ui/chrome/tab_drag_controller.cpp ui/input/binding_controller.cpp ui/input/key_bindings.cpp ui/terminal/copy_controller.cpp ui/links/link_controller.cpp)
  target_sources(gui-quick PRIVATE ui/palette/palette_actions.cpp ui/paths/path_picker_controller.cpp ui/paths/path_picker_controller.hpp ui/paths/path_picker_projection.cpp ui/suggestions/suggestion_controller.cpp ui/workspaces/workspace_form_controller.cpp ui/workspaces/workspace_form_controller.hpp)
  target_sources(gui-quick PRIVATE ui/machines/machine_controller.cpp ui/machines/machine_profile_controller.cpp ui/machines/machine_picker_controller.cpp ui/machines/machine_prompt_controller.cpp ui/machines/machine_prompt_controller.hpp ui/machines/machine_launch_controller.cpp ui/machines/machine_activity_controller.cpp)
  target_sources(gui-quick PRIVATE ui/store/store.cpp ui/store/store.hpp)
  target_sources(gui-quick PRIVATE ui/workspaces/workspaces_controller.cpp ui/workspaces/workspaces_controller.hpp ui/chrome/tabs_controller.cpp ui/chrome/tabs_controller.hpp ui/panes/panes_controller.cpp ui/panes/panes_controller.hpp ui/activity/activity_controller.cpp ui/activity/activity_controller.hpp ui/palette/palette_controller.cpp ui/palette/palette_controller.hpp)
  target_sources(gui-quick PRIVATE ui/peek/peek_controller.cpp ui/links/link_status_controller.cpp)
  set_source_files_properties(ui/palette/palette_controller.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  target_sources(gui-quick PRIVATE ui/history/history_empty_layout.cpp ui/history/history_empty_layout.hpp ui/history/history_loading_layout.cpp ui/history/history_loading_layout.hpp ui/history/history_selection_layout.cpp ui/history/history_selection_layout.hpp)
  target_sources(gui-quick PRIVATE ui/controls/modal_reveal_layout.cpp ui/controls/modal_reveal_layout.hpp)
  target_sources(gui-quick PRIVATE ui/panes/pane_motion_layout.cpp ui/panes/pane_motion_layout.hpp)
  set_source_files_properties(ui/controls/modal_reveal_layout.cpp ui/panes/pane_motion_layout.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  set_source_files_properties(ui/history/history_empty_layout.cpp ui/history/history_loading_layout.cpp ui/history/history_selection_layout.cpp ui/history/history_row_layout.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  target_sources(gui-quick PRIVATE ui/terminal/terminal_pointer.cpp ui/terminal/terminal_scroll.cpp ui/terminal/terminal_links.cpp ui/links/link_preview.cpp ui/input/pointer_dispatcher.cpp ui/input/native_pointer_events.cpp ui/history/history_scroll_events.cpp)
  target_sources(gui-quick PRIVATE ui/config/configuration_loader.cpp)
  target_sources(gui-quick PRIVATE ui/notifications/notification_controller.cpp ui/chrome/chrome_controller.cpp ui/app/application_effects.cpp)
  add_custom_target(gui-editor-ui
    COMMAND Python3::Interpreter "${CMAKE_CURRENT_SOURCE_DIR}/tools/create_editor_database.py" --build-dir "${CMAKE_CURRENT_BINARY_DIR}"
    DEPENDS tools/create_editor_database.py
    VERBATIM)
  add_dependencies(gui-editor gui-editor-ui)

  qt_add_executable(gui-host-effects-smoke tools/host_effects_smoke.cpp)
  target_link_libraries(gui-host-effects-smoke PRIVATE gui-core gui-unicode Qt6::Core Qt6::Gui)
  add_dependencies(gui-lint gui-host-effects-smoke)
  target_sources(gui-quick PRIVATE ui/notifications/notification_layout.cpp ui/notifications/notification_layout.hpp)
  target_sources(gui-quick PRIVATE ui/machines/machine_chrome_layout.cpp ui/machines/machine_chrome_layout.hpp)
  set_source_files_properties(ui/machines/machine_chrome_layout.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  target_sources(gui-quick PRIVATE ui/scene/curve_scene.cpp ui/scene/curve_mask_node.cpp ui/scene/alpha_mask_material.cpp ui/fonts/chrome_fonts.cpp ui/scene/chrome_text_scene.cpp ui/scene/ancestor_geometry.cpp)
  target_sources(gui-quick PRIVATE ui/scene/rounded_rectangle_scene.cpp ui/scene/software_rounded_rectangle.cpp)
  target_sources(gui-quick PRIVATE ui/controls/provider_artwork.cpp ui/fonts/resident_fonts.cpp ui/scene/chrome_icon_scene.cpp)
  target_sources(gui-quick PRIVATE ui/fonts/window_font_catalog.cpp ui/fonts/window_font_catalog.hpp)
  target_sources(gui-quick PRIVATE ui/panes/pane_header_layout.cpp ui/panes/pane_header_layout.hpp ui/controls/chrome_style.hpp)
  target_sources(gui-quick PRIVATE ui/history/history_row_layout.cpp ui/history/history_row_layout.hpp)
  target_sources(gui-quick PRIVATE ui/history/history_match_model.hpp)
  target_sources(gui-quick PRIVATE ui/history/history_meta_layout.cpp ui/history/history_meta_layout.hpp)
  target_sources(gui-quick PRIVATE ui/history/history_footer_layout.cpp ui/history/history_footer_layout.hpp ui/history/history_hint_projection.hpp)
  target_sources(gui-quick PRIVATE ui/history/history_filters_layout.cpp ui/history/history_filters_layout.hpp)
  target_sources(gui-quick PRIVATE ui/history/history_inspection_layout.cpp ui/history/history_inspection_layout.hpp)
  target_sources(gui-quick PRIVATE ui/controls/native_form_field.cpp ui/controls/native_form_field_input.cpp ui/controls/native_form_field.hpp ui/controls/form_composition_events.cpp)
  set_source_files_properties(ui/controls/native_form_field.cpp ui/controls/native_form_field_input.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  set_source_files_properties(ui/history/history_filters_layout.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  set_source_files_properties(ui/history/history_footer_layout.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  set_source_files_properties(ui/history/history_meta_layout.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  set_source_files_properties(ui/history/history_row_layout.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  target_sources(gui-quick PRIVATE ui/panes/fullscreen_strip_layout.cpp ui/panes/fullscreen_strip_layout.hpp)
  set_source_files_properties(ui/panes/fullscreen_strip_layout.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  target_sources(gui-quick PRIVATE ui/scene/window_animation_clock.cpp ui/chrome/native_tab_activity.cpp ui/chrome/native_tab_activity.hpp ui/controls/native_progress_ring.cpp ui/controls/native_progress_ring.hpp)
  target_sources(gui-quick PRIVATE ui/panes/native_pane_attention.cpp ui/panes/native_pane_attention.hpp)
  set_source_files_properties(ui/panes/native_pane_attention.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  set_source_files_properties(ui/panes/pane_header_layout.cpp ui/chrome/chrome_controller.cpp ui/notifications/notification_layout.cpp ui/scene/window_animation_clock.cpp ui/chrome/native_tab_activity.cpp ui/controls/native_progress_ring.cpp ui/activity/native_agent_status.cpp ui/scene/rounded_rectangle_scene.cpp ui/scene/software_rounded_rectangle.cpp ui/controls/native_rounded_rectangle.cpp ui/controls/provider_artwork.cpp ui/scene/chrome_text_scene.cpp ui/scene/chrome_icon_scene.cpp ui/controls/native_chrome_icon.cpp ui/controls/native_cell_text.cpp ui/chrome/native_mode_layout.cpp ui/chrome/tab_strip_layout.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  qt_add_shaders(gui-quick gui-curve-shaders
    PREFIX "/telar/shaders"
    BASE "${CMAKE_CURRENT_SOURCE_DIR}/ui/scene/shaders"
    BATCHABLE
    FILES ui/scene/shaders/alpha_mask.vert ui/scene/shaders/alpha_mask.frag ui/scene/shaders/nearest_alpha_mask.frag ui/scene/shaders/filtered_alpha_mask.frag ui/scene/shaders/tab_caption.frag)

  qt_add_shaders(gui-quick gui-shape-shaders
    PREFIX "/telar/shaders"
    BASE "${CMAKE_CURRENT_SOURCE_DIR}/ui/scene/shaders"
    BATCHABLE
    PERTARGETCOMPILE
    FILES ui/scene/shaders/rounded_rectangle.vert ui/scene/shaders/rounded_rectangle.frag)

  qt_add_shaders(gui-quick gui-straight-mask-shaders
    PREFIX "/telar/shaders"
    BASE "${CMAKE_CURRENT_SOURCE_DIR}/ui/scene/shaders"
    BATCHABLE
    DEFINES TELAR_STRAIGHT_ALPHA=1
    OUTPUTS straight/alpha_mask.frag.qsb straight/nearest_alpha_mask.frag.qsb straight/filtered_alpha_mask.frag.qsb
    FILES ui/scene/shaders/alpha_mask.frag ui/scene/shaders/nearest_alpha_mask.frag ui/scene/shaders/filtered_alpha_mask.frag)

  set_source_files_properties(ui/components/ComponentFit.js PROPERTIES QT_QML_SKIP_QMLDIR_ENTRY TRUE)

  # The generated QML type registrations include each registered header by its bare name.
  # Sources spell ui/ headers from src/gui; only the registrations need these folders.
  foreach(folder IN ITEMS activity app attachments chrome components controls documents history machines notifications palette panes paths prompt store terminal workspaces)
    target_include_directories(gui-quick PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/ui/${folder}")
  endforeach()

  qt_add_qml_module(gui-quick
    URI Telar.Gui
    VERSION 1.0
    OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/Telar/Gui"
    SOURCES ui/attachments/attachment_image.cpp ui/attachments/attachment_image.hpp ui/attachments/attachment_shelf.cpp ui/attachments/attachment_shelf.hpp ui/activity/native_agent_status.cpp ui/activity/native_agent_status.hpp ui/controls/native_rounded_rectangle.cpp ui/controls/native_rounded_rectangle.hpp ui/app/application.cpp ui/app/application.hpp ui/app/runtime_connection.cpp ui/app/runtime_connection.hpp ui/terminal/terminal_item.cpp ui/terminal/terminal_item.hpp ui/config/configuration_source.cpp ui/config/configuration_source.hpp ui/config/lua_host.cpp ui/config/lua_host.hpp ui/components/element_layout.cpp ui/components/element_layout.hpp ui/components/element_canvas.cpp ui/components/element_canvas.hpp ui/terminal/graphics_scene.cpp ui/terminal/graphics_scene.hpp ui/chrome/tab_strip_layout.cpp ui/chrome/tab_strip_layout.hpp ui/controls/provider_mark.cpp ui/controls/provider_mark.hpp ui/controls/native_chrome_text.cpp ui/controls/native_chrome_text.hpp ui/controls/native_chrome_icon.cpp ui/controls/native_chrome_icon.hpp ui/controls/native_cell_text.cpp ui/controls/native_cell_text.hpp ui/chrome/native_mode_layout.cpp ui/chrome/native_mode_layout.hpp ui/prompt/prompt_editor_item.cpp ui/prompt/prompt_editor_item.hpp ui/documents/document_view.cpp ui/documents/document_view.hpp
    QML_FILES ui/components/ComponentFit.js ui/components/Elements.js ui/components/ElementNode.qml ui/components/ElementHost.qml ui/components/ComponentPick.qml ui/components/ComponentBranch.qml ui/components/ComponentNode.qml ui/components/ComponentTree.qml ui/components/ComponentOverflow.qml ui/components/ComponentSlot.qml ui/components/ComponentPanel.qml ui/attachments/AttachmentShelf.qml ui/attachments/AttachmentModal.qml ui/peek/PeekPanel.qml ui/links/LinkStatus.qml ui/machines/MachineChrome.qml ui/machines/MachinePromptPanel.qml ui/prompt/PromptPanel.qml ui/prompt/PromptField.qml ui/prompt/PromptActions.qml ui/workspaces/WorkspaceFormPanel.qml ui/controls/FormTextField.qml ui/input/KeyboardAction.qml ui/input/ActionPointer.qml ui/app/Main.qml ui/controls/DialogSurface.qml ui/chrome/Sidebar.qml ui/chrome/TerminalTabs.qml ui/panes/PaneArea.qml ui/panes/PaneActions.qml ui/panes/PaneHeader.qml ui/panes/FullscreenStrip.qml ui/panes/PaneStatusChip.qml ui/panes/PaneProgress.qml ui/app/CommandDialog.qml ui/paths/PathPickerPanel.qml ui/palette/PalettePanel.qml ui/suggestions/SuggestionPanel.qml ui/palette/PaletteRow.qml ui/palette/PaletteKeycap.qml ui/palette/PaletteButton.qml ui/history/HistoryPanel.qml ui/history/HistoryKeys.qml ui/paths/PathKeys.qml ui/history/HistoryEmpty.qml ui/history/HistoryInspector.qml ui/controls/FormButton.qml ui/history/HistoryRow.qml ui/history/HistoryMeta.qml ui/history/HistoryHint.qml ui/history/HistoryFooter.qml ui/history/HistoryFilters.qml ui/history/HistoryFilterChip.qml ui/history/HistorySearchBar.qml ui/links/LinkPreview.qml ui/controls/ChromeText.qml ui/controls/ChromeToolTip.qml ui/controls/ChromeIcon.qml ui/controls/ChromeButton.qml ui/controls/ApplicationMark.qml ui/controls/ApplicationTile.qml ui/controls/ElevationShadow.qml ui/workspaces/WorkspaceList.qml ui/workspaces/ProjectRow.qml ui/workspaces/ProjectSwitcher.qml ui/workspaces/WorkspaceIdentity.qml ui/activity/ActivityList.qml ui/activity/ActivityFrame.qml ui/activity/AgentCard.qml ui/activity/AgentStatus.qml ui/activity/TaskCard.qml ui/activity/TaskPlan.qml ui/activity/CommandCard.qml ui/chrome/NavigationBar.qml ui/chrome/BarBattery.qml ui/chrome/BarSparkline.qml ui/chrome/BarMetric.qml ui/chrome/BarRing.qml ui/chrome/BarPill.qml ui/chrome/SystemSummary.qml ui/chrome/MetricsGroup.qml ui/chrome/StatusBar.qml ui/chrome/BarBadge.qml ui/controls/CellText.qml ui/chrome/ModeBar.qml ui/notifications/NotificationOverlay.qml ui/terminal/PromptLine.qml ui/terminal/CommandSeparators.qml ui/terminal/CommandRail.qml ui/terminal/JumpToEnd.qml ui/documents/DocumentView.qml ui/documents/DocumentBlock.qml ui/documents/DocumentTheme.qml ui/documents/InlineDocuments.qml)

  qt_add_executable(telar-gui main.cpp)
  if(APPLE)
    target_link_options(telar-gui PRIVATE -Wl,-headerpad_max_install_names)
    add_executable(telar-gui-launcher tools/macos_launcher.cpp platform/login_shell/login_shell.cpp)
    target_link_libraries(telar-gui-launcher PRIVATE gui-core)
    target_compile_options(telar-gui-launcher PRIVATE -Wall -Wextra -Werror)
    target_link_options(telar-gui-launcher PRIVATE -Wl,-headerpad_max_install_names)
    set_target_properties(telar-gui-launcher PROPERTIES AUTOMOC OFF AUTOUIC OFF AUTORCC OFF)
    add_dependencies(telar-gui telar-gui-launcher)
  endif()
  target_link_libraries(telar-gui PRIVATE gui-quick gui-quickplugin)
  add_dependencies(telar-gui telar-gui-command)
  add_dependencies(gui-lint telar-gui)

  set(gui_font_directory "${TELAR_ROOT}/assets")
  qt_add_resources(gui-quick gui-fonts
    PREFIX "/telar/fonts"
    BASE "${gui_font_directory}"
    FILES "${gui_font_directory}/JetBrainsMono-Regular.ttf" "${gui_font_directory}/SymbolsNerdFontMono-Regular.ttf" "${gui_font_directory}/IBMPlexSans-Regular.ttf" "${gui_font_directory}/IBMPlexSans-SemiBold.ttf" "${gui_font_directory}/TelarForma-Regular.ttf" "${gui_font_directory}/provider-symbols-320x64.rgba" "${gui_font_directory}/telar-mark-mono.svg" "${gui_font_directory}/telar-mark.svg" "${gui_font_directory}/telar-mark-shade.svg" "${gui_font_directory}/telar-mark-vesper.svg" "${gui_font_directory}/telar-mark-catppuccin.svg" "${gui_font_directory}/telar-mark-tokyo-night.svg" "${gui_font_directory}/telar-mark-pierre-dark.svg" "${gui_font_directory}/telar-mark-pierre-dark-soft.svg" "${gui_font_directory}/telar-mark-kanagawa.svg" "${gui_font_directory}/telar-mark-kanagawa-dragon.svg" "${gui_font_directory}/telar-mark-terminal.svg" "${gui_font_directory}/telar-mark-cybervenom.svg" "${gui_font_directory}/telar-mark-zenburn.svg")

  # Lucide line icons (ISC), which the mark item tints.
  set(gui_icon_directory "${TELAR_ROOT}/assets/icons")
  qt_add_resources(gui-quick gui-icons
    PREFIX "/telar/icons"
    BASE "${gui_icon_directory}"
    FILES "${gui_icon_directory}/bot.svg" "${gui_icon_directory}/chevron-down.svg" "${gui_icon_directory}/chevron-right.svg" "${gui_icon_directory}/git-branch.svg" "${gui_icon_directory}/server.svg" "${gui_icon_directory}/square-terminal.svg")

  add_dependencies(gui-editor gui-quick)

  if(BUILD_TESTING)
    if(APPLE)
      if(NOT DEFINED CMAKE_OBJC_COMPILER AND "$ENV{OBJC}" STREQUAL "" AND CMAKE_CXX_COMPILER_ID MATCHES "Clang")
        set(CMAKE_OBJC_COMPILER "${CMAKE_CXX_COMPILER}")
      endif()

      enable_language(OBJC)
      add_executable(gui-optical-text-test tests/optical_text_test.cpp)
      target_include_directories(gui-optical-text-test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/platform/macos")
      target_link_libraries(gui-optical-text-test PRIVATE gui-quick)
      add_test(NAME gui-optical-text COMMAND gui-optical-text-test)
      set_tests_properties(gui-optical-text PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
      add_dependencies(gui-lint gui-optical-text-test)
    endif()
    add_test(NAME gui-qt-dependency COMMAND Python3::Interpreter "${CMAKE_CURRENT_SOURCE_DIR}/tools/test_qt_dependency.py")
    set_tests_properties(gui-qt-dependency PROPERTIES ENVIRONMENT "TELAR_GUI_QT_CACHE=${CMAKE_CURRENT_BINARY_DIR}/CMakeCache.txt" TIMEOUT 30)
    find_package(Qt6 ${TELAR_QT_VERSION} EXACT REQUIRED COMPONENTS Test
      PATHS "${TELAR_GUI_QT_PREFIX}/lib/cmake/Qt6" NO_DEFAULT_PATH)
    # Package inspection hashes contents with OpenSSL; the GUI itself does not link it.
    include("${TELAR_ROOT}/cmake/openssl.cmake")
    add_executable(gui-plugin-packages-test tests/plugin_packages_test.cpp)
    target_link_libraries(gui-plugin-packages-test PRIVATE gui-posix Qt6::Core OpenSSL::Crypto gui-test-fixtures)
    add_test(NAME gui-plugin-packages COMMAND gui-plugin-packages-test)
    set_tests_properties(gui-plugin-packages PROPERTIES TIMEOUT 30)
    add_dependencies(gui-lint gui-plugin-packages-test)
    add_executable(gui-ssh-runtime-fixture tests/ssh_runtime_fixture.cpp)
    target_link_libraries(gui-ssh-runtime-fixture PRIVATE gui-core)
    add_dependencies(gui-lint gui-ssh-runtime-fixture)
    qt_add_executable(gui-remote-connection-test tests/remote_connection_test.cpp ui/app/runtime_connection.cpp ui/app/runtime_connection.hpp)
    target_link_libraries(gui-remote-connection-test PRIVATE gui-posix Qt6::Concurrent Qt6::Network Qt6::Test)
    target_include_directories(gui-remote-connection-test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    add_test(NAME gui-remote-connection COMMAND gui-remote-connection-test)
    set_tests_properties(gui-remote-connection PROPERTIES TIMEOUT 30)
    add_dependencies(gui-remote-connection-test gui-ssh-runtime-fixture)
    add_dependencies(gui-lint gui-remote-connection-test)
    qt_add_executable(gui-runtime-compatibility-probe tools/runtime_compatibility_probe.cpp ui/app/runtime_connection.cpp ui/app/runtime_connection.hpp)
    target_link_libraries(gui-runtime-compatibility-probe PRIVATE gui-posix Qt6::Concurrent Qt6::Network)
    target_include_directories(gui-runtime-compatibility-probe PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    add_dependencies(gui-lint gui-runtime-compatibility-probe)
    qt_add_executable(gui-local-runtime-endpoint-test tests/local_runtime_endpoint_test.cpp)
    target_link_libraries(gui-local-runtime-endpoint-test PRIVATE gui-posix Qt6::Network Qt6::Test)
    target_include_directories(gui-local-runtime-endpoint-test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    add_test(NAME gui-local-runtime-endpoint COMMAND gui-local-runtime-endpoint-test)
    set_tests_properties(gui-local-runtime-endpoint PROPERTIES TIMEOUT 30)
    add_dependencies(gui-lint gui-local-runtime-endpoint-test)
    qt_add_executable(gui-remote-bridge-test tests/remote_bridge_test.cpp)
    target_link_libraries(gui-remote-bridge-test PRIVATE gui-posix Qt6::Concurrent Qt6::Network Qt6::Test)
    target_include_directories(gui-remote-bridge-test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    add_test(NAME gui-remote-bridge COMMAND gui-remote-bridge-test)
    set_tests_properties(gui-remote-bridge PROPERTIES TIMEOUT 30)
    add_dependencies(gui-lint gui-remote-bridge-test)
    qt_add_executable(gui-machine-profile-window-test tests/machine_profile_window_test.cpp)
    target_link_libraries(gui-machine-profile-window-test PRIVATE gui-quick gui-quickplugin Qt6::Test)
    add_dependencies(gui-machine-profile-window-test gui-ssh-runtime-fixture)
    add_test(NAME gui-machine-profile-window COMMAND gui-machine-profile-window-test)
    set_tests_properties(gui-machine-profile-window PROPERTIES ENVIRONMENT "QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-machine-profile-window-test)
    qt_add_executable(gui-machine-window-test tests/machine_window_test.cpp)
    target_link_libraries(gui-machine-window-test PRIVATE gui-quick gui-quickplugin Qt6::Test gui-test-fixtures)
    if(APPLE)
      target_sources(gui-machine-window-test PRIVATE tests/platform/macos/private_clipboard.mm)
      target_include_directories(gui-machine-window-test PRIVATE tests)
      target_compile_options(gui-machine-window-test PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
      if(TELAR_GUI_HAS_OBJC_CLASS_STUB_CONTROL)
        target_compile_options(gui-machine-window-test PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fno-objc-msgsend-class-selector-stubs>")
      endif()
      if(TELAR_SANITIZERS)
        target_compile_options(gui-machine-window-test PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fsanitize=address,undefined;-fno-omit-frame-pointer>")
      endif()
    endif()

    add_test(NAME gui-machine-window COMMAND gui-machine-window-test)
    qt_add_executable(gui-prompt-window-test tests/prompt_window_test.cpp)
    target_link_libraries(gui-prompt-window-test PRIVATE gui-quick gui-quickplugin Qt6::Test gui-test-fixtures)
    target_include_directories(gui-prompt-window-test PRIVATE tests)
    add_test(NAME gui-prompt-window COMMAND gui-prompt-window-test)
    set_tests_properties(gui-prompt-window PROPERTIES ENVIRONMENT "QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-prompt-window-test)
    set_tests_properties(gui-machine-window PROPERTIES ENVIRONMENT "QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-machine-window-test)
    qt_add_executable(gui-machine-profiles-source-test tests/machine_profiles_source_test.cpp)
    target_link_libraries(gui-machine-profiles-source-test PRIVATE gui-machine-profiles Qt6::Test)
    add_test(NAME gui-machine-profiles-source COMMAND gui-machine-profiles-source-test)
    set_tests_properties(gui-machine-profiles-source PROPERTIES TIMEOUT 30)
    add_dependencies(gui-lint gui-machine-profiles-source-test)
    qt_add_executable(gui-window-frame-pacer-test tests/window_frame_pacer_test.cpp)
    target_link_libraries(gui-window-frame-pacer-test PRIVATE gui-core Qt6::Quick Qt6::Test)
    add_test(NAME gui-window-frame-pacer COMMAND gui-window-frame-pacer-test)
    set_tests_properties(gui-window-frame-pacer PROPERTIES ENVIRONMENT "QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-window-frame-pacer-test)
    if(APPLE)
      add_library(gui-test-window-activation STATIC tests/platform/macos/window_activation.mm tests/platform/window_hiding.cpp)
      target_link_libraries(gui-test-window-activation PUBLIC Qt6::Gui PRIVATE Qt6::GuiPrivate "-framework AppKit")
      if(TELAR_GUI_HAS_OBJC_CLASS_STUB_CONTROL)
        target_compile_options(gui-test-window-activation PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fno-objc-msgsend-class-selector-stubs>")
      endif()
    else()
      add_library(gui-test-window-activation STATIC tests/platform/window_activation.cpp tests/platform/window_hiding.cpp)
      target_link_libraries(gui-test-window-activation PUBLIC Qt6::Gui PRIVATE Qt6::GuiPrivate)
    endif()
    add_dependencies(gui-lint gui-test-window-activation)

    qt_add_executable(gui-chrome-text-test tests/chrome_text_test.cpp)
    qt_add_executable(gui-text-scene-probe tools/text_scene_probe.cpp)
    qt_add_executable(gui-terminal-scene-probe tools/terminal_scene_probe.cpp)
    target_link_libraries(gui-terminal-scene-probe PRIVATE gui-quick gui-quickplugin)
    add_dependencies(gui-lint gui-terminal-scene-probe)
    target_link_libraries(gui-text-scene-probe PRIVATE gui-quick gui-quickplugin)
    add_dependencies(gui-lint gui-text-scene-probe)
    target_link_libraries(gui-chrome-text-test PRIVATE gui-quick gui-quickplugin Qt6::Test gui-test-window-activation)
    add_test(NAME gui-chrome-text COMMAND gui-chrome-text-test)
    set_tests_properties(gui-chrome-text PROPERTIES ENVIRONMENT "QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-chrome-text-test)
    qt_add_executable(gui-chrome-icon-test tests/chrome_icon_test.cpp)
    qt_add_executable(gui-status-bar-test tests/status_bar_test.cpp)
    qt_add_executable(gui-rounded-rectangle-test tests/rounded_rectangle_test.cpp)
    target_link_libraries(gui-rounded-rectangle-test PRIVATE gui-quick gui-quickplugin Qt6::Test)
    qt_add_resources(gui-rounded-rectangle-test gui-shape-fixtures
      PREFIX "/telar/test-shapes"
      BASE "${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/shapes"
      FILES tests/fixtures/shapes/cases.json tests/fixtures/shapes/rounded-rectangles.png)
    add_test(NAME gui-rounded-rectangle COMMAND gui-rounded-rectangle-test)
    set_tests_properties(gui-rounded-rectangle PROPERTIES ENVIRONMENT "QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-rounded-rectangle-test)
    qt_add_executable(gui-mode-bar-test tests/mode_bar_test.cpp)
    target_link_libraries(gui-mode-bar-test PRIVATE gui-quick gui-quickplugin Qt6::Test)
    add_test(NAME gui-mode-bar COMMAND gui-mode-bar-test)
    set_tests_properties(gui-mode-bar PROPERTIES ENVIRONMENT "QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-mode-bar-test)
    target_link_libraries(gui-status-bar-test PRIVATE gui-quick gui-quickplugin Qt6::Test gui-test-fixtures)
    add_test(NAME gui-status-bar COMMAND gui-status-bar-test)
    set_tests_properties(gui-status-bar PROPERTIES ENVIRONMENT "QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-status-bar-test)
    target_link_libraries(gui-chrome-icon-test PRIVATE gui-quick gui-quickplugin Qt6::Test gui-test-window-activation)
    qt_add_resources(gui-chrome-icon-test gui-icon-fixtures
      PREFIX "/telar/test-icons"
      BASE "${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/icons"
      FILES tests/fixtures/icons/folder-small.png tests/fixtures/icons/unknown-status.png)
    add_test(NAME gui-chrome-icon COMMAND gui-chrome-icon-test)
    set_tests_properties(gui-chrome-icon PROPERTIES ENVIRONMENT "QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-chrome-icon-test)
    qt_add_executable(gui-tab-activity-scene-test tests/tab_activity_scene_test.cpp)
    target_link_libraries(gui-tab-activity-scene-test PRIVATE gui-quick gui-quickplugin Qt6::Test)
    qt_add_resources(gui-tab-activity-scene-test gui-progress-fixtures
      PREFIX "/telar/test-tab-activity"
      BASE "${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/tab-activity"
      FILES tests/fixtures/tab-activity/cases.json tests/fixtures/tab-activity/atlas.png)
    target_compile_options(gui-tab-activity-scene-test PRIVATE -ffp-contract=off)
    add_test(NAME gui-tab-activity-scene COMMAND gui-tab-activity-scene-test)
    set_tests_properties(gui-tab-activity-scene PROPERTIES ENVIRONMENT "QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-tab-activity-scene-test)
    qt_add_executable(gui-graphics-retention-scene-test tests/graphics_retention_scene_test.cpp)
    target_link_libraries(gui-graphics-retention-scene-test PRIVATE gui-quick gui-quickplugin Qt6::Test)
    add_test(NAME gui-graphics-retention-scene COMMAND gui-graphics-retention-scene-test)
    set_tests_properties(gui-graphics-retention-scene PROPERTIES ENVIRONMENT "QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-graphics-retention-scene-test)
    qt_add_executable(gui-graphics-recovery-scene-test tests/graphics_recovery_scene_test.cpp tests/controlled_awake_clock.cpp)
    target_link_libraries(gui-graphics-recovery-scene-test PRIVATE gui-quick gui-quickplugin Qt6::Test)
    add_test(NAME gui-graphics-recovery-scene COMMAND gui-graphics-recovery-scene-test)
    set_tests_properties(gui-graphics-recovery-scene PROPERTIES ENVIRONMENT "QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-graphics-recovery-scene-test)
    qt_add_executable(gui-pane-attention-test tests/pane_attention_test.cpp tests/controlled_awake_clock.cpp)
    target_link_libraries(gui-pane-attention-test PRIVATE gui-quick gui-quickplugin Qt6::Test)
    qt_add_resources(gui-pane-attention-test gui-pane-attention-fixtures
      PREFIX "/telar/test-pane-attention"
      BASE "${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/pane-attention"
      FILES tests/fixtures/pane-attention/cases.json tests/fixtures/pane-attention/alpha-0.png tests/fixtures/pane-attention/alpha-90000000.png tests/fixtures/pane-attention/alpha-180000000.png tests/fixtures/pane-attention/alpha-360000000.png)
    target_compile_options(gui-pane-attention-test PRIVATE -ffp-contract=off)
    add_test(NAME gui-pane-attention COMMAND gui-pane-attention-test)
    set_tests_properties(gui-pane-attention PROPERTIES ENVIRONMENT "QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-pane-attention-test)
    qt_add_executable(gui-notification-overlay-test tests/notification_overlay_test.cpp)
    target_link_libraries(gui-notification-overlay-test PRIVATE gui-quick gui-quickplugin Qt6::Test gui-test-window-activation)
    add_test(NAME gui-notification-overlay COMMAND gui-notification-overlay-test)
    set_tests_properties(gui-notification-overlay PROPERTIES ENVIRONMENT "QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-notification-overlay-test)
    qt_add_executable(gui-project-row-test tests/project_row_test.cpp)
    target_link_libraries(gui-project-row-test PRIVATE gui-quick gui-quickplugin Qt6::Test)
    add_test(NAME gui-project-row COMMAND gui-project-row-test)
    set_tests_properties(gui-project-row PROPERTIES ENVIRONMENT "QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-project-row-test)
    qt_add_executable(gui-chrome-test tests/chrome_test.cpp)
    target_link_libraries(gui-chrome-test PRIVATE gui-quick gui-quickplugin Qt6::Test)
    add_test(NAME gui-chrome COMMAND gui-chrome-test)
    set_tests_properties(gui-chrome PROPERTIES ENVIRONMENT "QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-chrome-test)
    qt_add_executable(gui-pane-header-test tests/pane_header_test.cpp)
    target_link_libraries(gui-pane-header-test PRIVATE gui-quick gui-quickplugin Qt6::Test)
    add_test(NAME gui-pane-header COMMAND gui-pane-header-test)
    set_tests_properties(gui-pane-header PROPERTIES ENVIRONMENT "QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-pane-header-test)
    qt_add_executable(gui-fullscreen-strip-test tests/fullscreen_strip_test.cpp)
    target_link_libraries(gui-fullscreen-strip-test PRIVATE gui-quick gui-quickplugin Qt6::Test)
    add_test(NAME gui-fullscreen-strip COMMAND gui-fullscreen-strip-test)
    set_tests_properties(gui-fullscreen-strip PROPERTIES ENVIRONMENT "QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-fullscreen-strip-test)
    qt_add_executable(gui-agent-timeline-test tests/agent_timeline_test.cpp)
    target_link_libraries(gui-agent-timeline-test PRIVATE gui-quick gui-quickplugin Qt6::Test gui-test-fixtures)
    add_test(NAME gui-agent-timeline COMMAND gui-agent-timeline-test)
    set_tests_properties(gui-agent-timeline PROPERTIES ENVIRONMENT "QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-agent-timeline-test)
    qt_add_executable(gui-agent-card-test tests/agent_card_test.cpp)
    target_link_libraries(gui-agent-card-test PRIVATE gui-quick gui-quickplugin Qt6::Test)
    add_test(NAME gui-agent-card COMMAND gui-agent-card-test)
    set_tests_properties(gui-agent-card PROPERTIES ENVIRONMENT "QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-agent-card-test)
    qt_add_executable(gui-task-card-test tests/task_card_test.cpp)
    target_link_libraries(gui-task-card-test PRIVATE gui-quick gui-quickplugin Qt6::Test gui-test-fixtures)
    add_test(NAME gui-task-card COMMAND gui-task-card-test)
    set_tests_properties(gui-task-card PROPERTIES ENVIRONMENT "QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-task-card-test)
    qt_add_executable(gui-window-test tests/window_test.cpp)
    target_link_libraries(gui-window-test PRIVATE gui-quick gui-quickplugin Qt6::Test)
    add_test(NAME gui-window COMMAND gui-window-test)
    set_tests_properties(gui-window PROPERTIES ENVIRONMENT "QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-window-test)
    qt_add_executable(gui-font-resolver-test tests/font_resolver_test.cpp)
    qt_add_resources(gui-font-resolver-test gui-font-fixtures
      PREFIX "/telar/test-fonts"
      BASE "${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures"
      FILES tests/fixtures/metrics-variable.ttf tests/fixtures/metrics-collection.ttc tests/fixtures/metrics-wide-glyph.ttf)
    target_link_libraries(gui-font-resolver-test PRIVATE gui-quick gui-quickplugin Qt6::Test)
    add_test(NAME gui-font-resolver COMMAND gui-font-resolver-test)
    set_tests_properties(gui-font-resolver PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-font-resolver-test)
    qt_add_executable(gui-configuration-source-test tests/configuration_source_test.cpp)
    target_link_libraries(gui-configuration-source-test PRIVATE gui-quick gui-quickplugin Qt6::Test gui-test-fixtures)
    add_test(NAME gui-configuration-source COMMAND gui-configuration-source-test)
    set_tests_properties(gui-configuration-source PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-configuration-source-test)
    qt_add_executable(gui-configuration-reload-probe tools/configuration_reload_probe.cpp)
    target_link_libraries(gui-configuration-reload-probe PRIVATE gui-quick gui-quickplugin)
    add_dependencies(gui-lint gui-configuration-reload-probe)
    qt_add_executable(gui-separators-probe tools/separators_probe.cpp)
    target_link_libraries(gui-separators-probe PRIVATE gui-quick gui-quickplugin gui-test-fixtures)
    add_dependencies(gui-lint gui-separators-probe)
    add_executable(gui-key-adapter-test tests/key_adapter_test.cpp)
    target_link_libraries(gui-key-adapter-test PRIVATE gui-keyboard)
    add_test(NAME gui-key-adapter COMMAND gui-key-adapter-test)
    set_tests_properties(gui-key-adapter PROPERTIES TIMEOUT 30)
    add_dependencies(gui-lint gui-key-adapter-test)
    qt_add_executable(gui-link-opener-test tests/link_opener_test.cpp)
    target_link_libraries(gui-link-opener-test PRIVATE gui-core gui-unicode Qt6::Gui Qt6::Test)
    target_include_directories(gui-link-opener-test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    add_test(NAME gui-link-opener COMMAND gui-link-opener-test)
    set_tests_properties(gui-link-opener PROPERTIES TIMEOUT 30)
    add_dependencies(gui-lint gui-link-opener-test)
    qt_add_executable(gui-plugin-worker-test tests/plugin_worker_test.cpp)
    target_link_libraries(gui-plugin-worker-test PRIVATE gui-posix Qt6::Concurrent Qt6::Test)
    target_include_directories(gui-plugin-worker-test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    add_test(NAME gui-plugin-worker COMMAND gui-plugin-worker-test)
    set_tests_properties(gui-plugin-worker PROPERTIES TIMEOUT 30)
    add_dependencies(gui-lint gui-plugin-worker-test)
    add_executable(gui-pick-controller-test tests/pick_controller_test.cpp)
    target_link_libraries(gui-pick-controller-test PRIVATE gui-config gui-surface-command)
    add_test(NAME gui-pick-controller COMMAND gui-pick-controller-test)
    set_tests_properties(gui-pick-controller PROPERTIES TIMEOUT 30)
    add_dependencies(gui-lint gui-pick-controller-test)
    qt_add_executable(gui-host-effects-test tests/host_effects_test.cpp)
    target_link_libraries(gui-host-effects-test PRIVATE gui-core gui-unicode Qt6::Core Qt6::Gui Qt6::Test gui-test-fixtures)
    add_test(NAME gui-host-effects COMMAND gui-host-effects-test)
    set_tests_properties(gui-host-effects PROPERTIES TIMEOUT 30)
    add_dependencies(gui-lint gui-host-effects-test)
    qt_add_executable(gui-scene-test tests/scene_test.cpp)
    target_link_libraries(gui-scene-test PRIVATE gui-quick gui-quickplugin Qt6::Test)
    add_test(NAME gui-scene COMMAND gui-scene-test)
    set_tests_properties(gui-scene PROPERTIES ENVIRONMENT "QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 60)
    add_dependencies(gui-lint gui-scene-test)
    qt_add_executable(gui-form-field-test tests/form_field_test.cpp)
    target_link_libraries(gui-form-field-test PRIVATE gui-quick gui-quickplugin Qt6::Test gui-test-window-activation)
    add_test(NAME gui-form-field COMMAND gui-form-field-test)
    set_tests_properties(gui-form-field PROPERTIES ENVIRONMENT "QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-form-field-test)
    add_executable(gui-list-model-test tests/list_model_test.cpp)
    target_include_directories(gui-list-model-test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    target_link_libraries(gui-list-model-test PRIVATE Qt6::Gui Qt6::Test)
    add_test(NAME gui-list-model COMMAND gui-list-model-test)
    set_tests_properties(gui-list-model PROPERTIES TIMEOUT 30)
    add_dependencies(gui-lint gui-list-model-test)
    qt_add_executable(gui-history-controls-test tests/history_controls_test.cpp)
    target_link_libraries(gui-history-controls-test PRIVATE gui-quick gui-quickplugin Qt6::Test gui-test-window-activation)
    add_test(NAME gui-history-controls COMMAND gui-history-controls-test)
    set_tests_properties(gui-history-controls PROPERTIES ENVIRONMENT "QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-history-controls-test)
    qt_add_executable(gui-modal-reveal-test tests/modal_reveal_test.cpp)
    target_link_libraries(gui-modal-reveal-test PRIVATE gui-quick gui-quickplugin Qt6::Test gui-test-window-activation)
    add_test(NAME gui-modal-reveal COMMAND gui-modal-reveal-test)
    set_tests_properties(gui-modal-reveal PROPERTIES ENVIRONMENT "QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-modal-reveal-test)
    qt_add_executable(gui-pane-motion-test tests/pane_motion_test.cpp)
    target_link_libraries(gui-pane-motion-test PRIVATE gui-quick gui-quickplugin Qt6::Test gui-test-window-activation)
    target_compile_options(gui-pane-motion-test PRIVATE -ffp-contract=off)
    add_test(NAME gui-pane-motion COMMAND gui-pane-motion-test)
    set_tests_properties(gui-pane-motion PROPERTIES ENVIRONMENT "QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    add_dependencies(gui-lint gui-pane-motion-test)
    add_test(NAME gui-animation-cadence-tools COMMAND Python3::Interpreter "${CMAKE_CURRENT_SOURCE_DIR}/tools/test_animation_cadence.py")
    set_tests_properties(gui-animation-cadence-tools PROPERTIES TIMEOUT 10)
    if(APPLE)
      qt_add_executable(gui-animation-probe tools/animation_probe.cpp tools/animation_presentation.mm)
      target_include_directories(gui-animation-probe PRIVATE tests)
      target_link_libraries(gui-animation-probe PRIVATE gui-quick gui-quickplugin gui-test-window-activation "-framework Metal" "-framework QuartzCore")
      target_compile_options(gui-animation-probe PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
      if(TELAR_GUI_HAS_OBJC_CLASS_STUB_CONTROL)
        target_compile_options(gui-animation-probe PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fno-objc-msgsend-class-selector-stubs>")
      endif()
      add_dependencies(gui-lint gui-animation-probe)
    endif()
    qt_add_executable(gui-quick-test tests/quick_test.cpp tests/agent_report_fixture.cpp)
    target_link_libraries(gui-quick-test PRIVATE gui-quick gui-quickplugin Qt6::Test gui-test-window-activation gui-test-fixtures)
    add_dependencies(gui-lint gui-quick-test)
    qt_add_executable(gui-suggestion-controls-test tests/suggestion_controls_test.cpp)
    target_link_libraries(gui-suggestion-controls-test PRIVATE gui-quick gui-quickplugin Qt6::Test gui-test-window-activation)
    target_compile_definitions(gui-suggestion-controls-test PRIVATE
      TELAR_GUI_TEST_PYTHON="${Python3_EXECUTABLE}"
      TELAR_GUI_SUGGESTION_FIXTURE="${CMAKE_CURRENT_SOURCE_DIR}/tests/suggestion_engine_fixture.py")
    add_dependencies(gui-lint gui-suggestion-controls-test)
    set(TELAR_GUI_TEST_RUNTIME "" CACHE FILEPATH "Runtime executable for native GUI integration tests")
    if(TELAR_GUI_TEST_RUNTIME)
      get_filename_component(gui_test_runtime_directory "${TELAR_GUI_TEST_RUNTIME}" DIRECTORY)
      add_test(NAME gui-quick COMMAND gui-quick-test)
      set_tests_properties(gui-quick PROPERTIES ENVIRONMENT "TELAR_GUI_TEST_RUNTIME=${TELAR_GUI_TEST_RUNTIME};PATH=${gui_test_runtime_directory}:$ENV{PATH};QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 90)
      add_test(NAME gui-suggestion-controls COMMAND gui-suggestion-controls-test)
      set_tests_properties(gui-suggestion-controls PROPERTIES ENVIRONMENT "TELAR_GUI_TEST_RUNTIME=${TELAR_GUI_TEST_RUNTIME};QT_QUICK_BACKEND=software;QT_QPA_PLATFORM=offscreen" TIMEOUT 90)
    endif()
  endif()

  telar_verify_qt_packages()
  install(TARGETS telar-gui BUNDLE DESTINATION . RUNTIME DESTINATION bin)
  install(TARGETS telar-gui-command RUNTIME DESTINATION bin)
  install(FILES terminal/glyphs/LICENSE DESTINATION share/licenses/telar-gui RENAME cell-glyphs.txt)
  install(FILES licenses/ghostty-vt.txt DESTINATION share/licenses/telar-gui)
  install(FILES "${TELAR_ROOT}/assets/icons/LICENSE" DESTINATION share/licenses/telar-gui RENAME lucide.txt)
  install(FILES "${gui_font_directory}/JetBrainsMono-OFL.txt" "${gui_font_directory}/TelarForma-OFL.txt" DESTINATION share/licenses/telar-gui)
endif()

# Nearly all of a gui-quick compilation is its imported BMIs and Qt headers, which
# every source repeats, so sources compiled together cost little more than one.
# CMake's UNITY_BUILD refuses sources it scans for modules; ordinary generated
# units including them keep the native dependency scan. File-local names must
# therefore stay unique across the batched ui/*.cpp sources.
function(telar_gui_batch_sources target batch_size)
  get_target_property(target_sources ${target} SOURCES)
  set(kept)
  set(batched)
  foreach(source IN LISTS target_sources)
    if(source MATCHES "^ui/.*\\.cpp$")
      # gui-core already gives every gui-quick source -ffp-contract=off.
      get_source_file_property(source_options "${source}" COMPILE_OPTIONS)
      if(NOT source_options OR source_options STREQUAL "-ffp-contract=off")
        list(APPEND batched "${source}")
        # AUTOMOC finds a header through its source, which leaves the target.
        string(REGEX REPLACE "\\.cpp$" ".hpp" header "${source}")
        if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/${header}")
          list(APPEND kept "${header}")
        endif()
        continue()
      endif()
    endif()
    list(APPEND kept "${source}")
  endforeach()
  list(SORT batched)
  list(LENGTH batched batched_count)
  set(index 0)
  set(batch 0)
  while(index LESS batched_count)
    list(SUBLIST batched ${index} ${batch_size} members)
    set(content "")
    foreach(member IN LISTS members)
      string(APPEND content "#include \"${CMAKE_CURRENT_SOURCE_DIR}/${member}\"\n")
    endforeach()
    set(unit "${CMAKE_CURRENT_BINARY_DIR}/${target}_batch_${batch}.cpp")
    file(GENERATE OUTPUT "${unit}" CONTENT "${content}")
    set_source_files_properties("${unit}" PROPERTIES GENERATED TRUE CXX_SCAN_FOR_MODULES ON SKIP_AUTOMOC ON)
    list(APPEND kept "${unit}")
    math(EXPR index "${index} + ${batch_size}")
    math(EXPR batch "${batch} + 1")
  endwhile()
  list(REMOVE_DUPLICATES kept)
  set_target_properties(${target} PROPERTIES SOURCES "${kept}")
endfunction()
if(TARGET gui-quick AND TELAR_GUI_BATCH_SIZE GREATER 0)
  telar_gui_batch_sources(gui-quick ${TELAR_GUI_BATCH_SIZE})
endif()

# moc includes the textual QObject headers, which import domain modules. Their
# generated translation units must participate in the same native dependency scan.
get_property(gui_targets DIRECTORY PROPERTY BUILDSYSTEM_TARGETS)
foreach(gui_target IN LISTS gui_targets)
  get_target_property(gui_automoc ${gui_target} AUTOMOC)
  if(gui_automoc)
    get_target_property(gui_autogen_directory ${gui_target} AUTOGEN_BUILD_DIR)
    if(NOT gui_autogen_directory)
      set(gui_autogen_directory "${CMAKE_CURRENT_BINARY_DIR}/${gui_target}_autogen")
    endif()
    # CMake deliberately disables scanning on its synthetic moc source. A
    # separate ordinary generated unit lets the scanner discover header imports.
    set_source_files_properties("${gui_autogen_directory}/mocs_compilation.cpp"
      PROPERTIES HEADER_FILE_ONLY ON)
    set(gui_moc_imports "${CMAKE_CURRENT_BINARY_DIR}/${gui_target}_moc_imports.cpp")
    file(GENERATE OUTPUT "${gui_moc_imports}"
      CONTENT "#include \"${gui_autogen_directory}/mocs_compilation.cpp\"\n")
    set_source_files_properties("${gui_moc_imports}" PROPERTIES GENERATED TRUE CXX_SCAN_FOR_MODULES ON SKIP_AUTOMOC ON)
    target_sources(${gui_target} PRIVATE "${gui_moc_imports}")
  endif()
endforeach()

# Probes and smoke tools run by hand or by tools/ scripts, never by CTest: building them on
# every test run costs a full module compile each. `cmake --build out --target gui-probes`
# builds the ones this platform and configuration define.
set(gui_probes gui-screen-probe gui-glyph-ink-probe gui-font-coverage-probe gui-display-probe gui-runtime-compatibility-probe gui-text-scene-probe gui-terminal-scene-probe gui-configuration-reload-probe gui-separators-probe gui-animation-probe gui-host-effects-smoke)
set(gui_defined_probes)
foreach(probe IN LISTS gui_probes)
  if(TARGET ${probe})
    set_target_properties(${probe} PROPERTIES EXCLUDE_FROM_ALL ON)
    list(APPEND gui_defined_probes ${probe})
  endif()
endforeach()
add_custom_target(gui-probes DEPENDS ${gui_defined_probes})
