project(telar_gui LANGUAGES C CXX)

option(TELAR_GUI_NATIVE "Build the native window" ON)
# clangd, lint and per-file incremental rebuilds need one compile command per source.
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
  set(telar_gui_batch_default 0)
else()
  set(telar_gui_batch_default 12)
endif()
set(TELAR_GUI_BATCH_SIZE ${telar_gui_batch_default} CACHE STRING "Sources compiled together in gui-quick; 0 compiles each one alone")

get_filename_component(TELAR_ROOT "../.." ABSOLUTE)
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
telar_modules(gui-core
  MACOS_SOURCES fonts/glyph_rasterizer/glyph_rasterizer.cppm
  LINUX_SOURCES platform/background_effect/background_effect.cppm)
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
target_link_libraries(gui-core PUBLIC tbc::tbc telar::shell telar::render ebnf::ebnf)
target_include_directories(gui-core PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/generated")
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
target_link_libraries(telar-gui-command PRIVATE telar::build_flags)

add_library(gui-config INTERFACE)
target_link_libraries(gui-core PUBLIC deps::ghostty_vt)
target_link_libraries(gui-config INTERFACE gui-core deps::ghostty_vt)
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

if(TELAR_GUI_NATIVE)
  add_library(gui-fonts STATIC fonts/face/face.cpp fonts/face/ligature_coverage.cpp fonts/font_requests/font_requests.cpp fonts/row_text_layout/row_text_layout.cpp)
  target_link_libraries(gui-fonts PUBLIC gui-core gui-harfbuzz)
  target_link_libraries(gui-editor-context INTERFACE gui-fonts)
  target_compile_options(gui-fonts PRIVATE -ffp-contract=off)

  include(cmake/qt.cmake)
  find_package(Qt6 ${TELAR_QT_VERSION} EXACT REQUIRED COMPONENTS Gui Qml Quick QuickControls2 Network Concurrent ShaderTools Svg
    PATHS "${TELAR_GUI_QT_PREFIX}/lib/cmake/Qt6" NO_DEFAULT_PATH)
  find_package(Qt6GuiPrivate ${TELAR_QT_VERSION} EXACT REQUIRED CONFIG
    PATHS "${TELAR_GUI_QT_PREFIX}/lib/cmake/Qt6GuiPrivate" NO_DEFAULT_PATH)
  qt_standard_project_setup(REQUIRES 6.7)
  add_library(gui-surface-command STATIC ui/components/surface_command.cpp)
  target_link_libraries(gui-surface-command PUBLIC gui-posix Qt6::Core)
  add_dependencies(gui-surface-command telar-gui-command)

  add_library(gui-machine-profiles STATIC ui/machine_prompt/machine_profiles_source.cpp ui/machine_prompt/machine_profiles_source.hpp)
  target_link_libraries(gui-machine-profiles PUBLIC gui-posix Qt6::Concurrent)
  if(Qt6_VERSION VERSION_GREATER_EQUAL 6.8)
    qt_policy(SET QTP0004 NEW)
  endif()

  add_library(gui-platform STATIC platform/login_shell/host_name.cpp)
  target_link_libraries(gui-platform PUBLIC gui-core gui-posix Qt6::Gui PRIVATE Qt6::Quick)
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
    target_sources(gui-platform PRIVATE platform/macos/font.mm platform/macos/glyph_rasterizer.mm fonts/glyph_rasterizer/glyph_rasterizer.cpp)
    target_sources(gui-platform PRIVATE platform/macos/optical_text.mm)
    target_link_libraries(gui-platform PRIVATE Qt6::GuiPrivate)
    target_compile_options(gui-platform PRIVATE "$<$<COMPILE_LANGUAGE:OBJC,OBJCXX>:-fobjc-arc>")
    if(TELAR_GUI_HAS_OBJC_CLASS_STUB_CONTROL)
      target_compile_options(gui-platform PRIVATE "$<$<COMPILE_LANGUAGE:OBJC,OBJCXX>:-fno-objc-msgsend-class-selector-stubs>")
    endif()

    target_link_libraries(gui-platform PRIVATE "-framework AppKit" "-framework CoreText" "-framework CoreGraphics" "-framework ImageIO")
    # The clipboard image source test checks this source under the sanitizers.
    if(BUILD_TESTING AND TELAR_SANITIZERS)
      set_property(SOURCE platform/macos/clipboard_image_source.mm APPEND PROPERTY COMPILE_OPTIONS -fsanitize=address,undefined -fno-omit-frame-pointer)
    endif()

  elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    find_package(Fontconfig REQUIRED)
    find_package(Qt6 ${TELAR_QT_VERSION} EXACT REQUIRED COMPONENTS WaylandClient
      PATHS "${TELAR_GUI_QT_PREFIX}/lib/cmake/Qt6" NO_DEFAULT_PATH)
    find_package(Qt6WaylandClientPrivate ${TELAR_QT_VERSION} EXACT REQUIRED CONFIG
      PATHS "${TELAR_GUI_QT_PREFIX}/lib/cmake/Qt6WaylandClientPrivate" NO_DEFAULT_PATH)
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
  else()
    message(FATAL_ERROR "The GUI supports macOS and Linux")
  endif()

  add_library(gui-keyboard STATIC ui/foundation/input/terminal_input.cpp)
  target_link_libraries(gui-keyboard PUBLIC gui-core Qt6::Gui)

  add_library(gui-clipboard-images STATIC ui/attachments/attachment_preview.cpp ui/attachments/attachment_preview.hpp ui/attachments/clipboard_images.cpp ui/attachments/clipboard_images.hpp)
  target_link_libraries(gui-clipboard-images PUBLIC gui-platform Qt6::Concurrent)

  qt_add_library(gui-quick STATIC)
  target_link_libraries(gui-quick PRIVATE Qt6::GuiPrivate)
  target_sources(gui-quick PRIVATE ui/terminal/window_images.cpp ui/terminal/image_resource.cpp)
  target_link_libraries(gui-quick PUBLIC gui-clipboard-images)
  set_source_files_properties(ui/attachments/attachment_preview.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")

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

  target_sources(gui-quick PRIVATE ui/attachments/attachments_controller.cpp ui/attachments/attachments_controller.hpp ui/app/plugin_commands.cpp ui/plugins/plugin_runner.cpp ui/plugins/plugin_runner.hpp ui/app/prompt_commands.cpp ui/prompt/prompt_controller.cpp ui/prompt/prompt_controller.hpp ui/documents/documents_controller.cpp ui/documents/documents_controller.hpp)
  target_sources(gui-quick PRIVATE ui/components/components_controller.cpp ui/components/components_controller.hpp ui/app/component_commands.cpp ui/app/element_commands.cpp ui/design/elements/element_slots.cpp ui/design/elements/element_slots.hpp)
  target_link_libraries(gui-quick PRIVATE gui-surface-command Qt6::Svg)
  target_sources(gui-quick PRIVATE ui/history/history_controller.cpp ui/history/history_controller.hpp ui/history/history_pointer.cpp ui/app/binding_commands.cpp ui/app/key_bindings.cpp ui/terminal/copy_controller.cpp ui/terminal/copy_controller.hpp ui/terminal/terminal_controller.cpp ui/terminal/terminal_controller.hpp ui/terminal/terminal_host.hpp ui/app/terminal_host.cpp ui/foundation/links/links_controller.cpp ui/foundation/links/links_controller.hpp)
  target_sources(gui-quick PRIVATE ui/app/palette_commands.cpp ui/paths/path_picker_controller.cpp ui/paths/path_picker_controller.hpp ui/paths/path_picker_projection.cpp ui/workspaces/workspace_form_controller.cpp ui/workspaces/workspace_form_controller.hpp)
  target_sources(gui-quick PRIVATE ui/app/machine_clients.cpp ui/app/machine_profiles.cpp ui/app/machine_actions.cpp ui/machine_prompt/machine_prompt_controller.cpp ui/machine_prompt/machine_prompt_controller.hpp ui/app/machine_launch.cpp ui/app/activity_selection.cpp)
  target_sources(gui-quick PRIVATE ui/store/store.cpp ui/store/store.hpp)
  target_sources(gui-quick PRIVATE ui/foundation/input/window_actions.hpp)
  target_sources(gui-quick PRIVATE ui/workspaces/workspaces_controller.cpp ui/workspaces/workspaces_controller.hpp ui/chrome/tabs_controller.cpp ui/chrome/tabs_controller.hpp ui/chrome/sidebar_controller.cpp ui/chrome/sidebar_controller.hpp ui/panes/panes_controller.cpp ui/panes/panes_controller.hpp ui/activity/activity_controller.cpp ui/activity/activity_controller.hpp ui/foundation/models/machine_activity_target.cpp ui/foundation/models/machine_activity_target.hpp ui/palette/palette_controller.cpp ui/palette/palette_controller.hpp)
  target_sources(gui-quick PRIVATE ui/peek/peek_controller.cpp ui/peek/peek_controller.hpp ui/link_status/link_status_controller.cpp ui/link_status/link_status_controller.hpp)
  set_source_files_properties(ui/palette/palette_controller.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  target_sources(gui-quick PRIVATE ui/history/history_empty_layout.cpp ui/history/history_empty_layout.hpp ui/history/history_loading_layout.cpp ui/history/history_loading_layout.hpp ui/history/history_selection_layout.cpp ui/history/history_selection_layout.hpp)
  target_sources(gui-quick PRIVATE ui/controls/modal_reveal_layout.cpp ui/controls/modal_reveal_layout.hpp)
  target_sources(gui-quick PRIVATE ui/panes/pane_motion_layout.cpp ui/panes/pane_motion_layout.hpp)
  set_source_files_properties(ui/controls/modal_reveal_layout.cpp ui/panes/pane_motion_layout.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  set_source_files_properties(ui/history/history_empty_layout.cpp ui/history/history_loading_layout.cpp ui/history/history_selection_layout.cpp ui/history/history_row_layout.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  target_sources(gui-quick PRIVATE ui/terminal/terminal_pointer.cpp ui/terminal/terminal_scroll.cpp ui/terminal/terminal_links.cpp ui/links/link_preview.cpp ui/app/pointer_dispatcher.cpp ui/foundation/input/native_pointer_events.cpp)
  target_sources(gui-quick PRIVATE ui/config/configuration_loader.cpp)
  target_sources(gui-quick PRIVATE ui/app/notification_commands.cpp ui/app/graphics_recovery.cpp ui/notifications/notifications_controller.cpp ui/notifications/notifications_controller.hpp ui/app/window_geometry.cpp ui/app/application_effects.cpp ui/foundation/machines/machine_effects.cpp ui/foundation/machines/machine_effects.hpp)
  add_custom_target(gui-editor-ui
    COMMAND Python3::Interpreter "${CMAKE_CURRENT_SOURCE_DIR}/tools/create_editor_database.py" --build-dir "${CMAKE_BINARY_DIR}"
    DEPENDS tools/create_editor_database.py
    VERBATIM)
  add_dependencies(gui-editor gui-editor-ui)
  # Run by hand by tools/check_notification_desktop.py, so a tree configured without
  # tests builds it too.
  telar_add_test(gui-host-effects-smoke QT PROBE SOURCES tools/host_effects_smoke.cpp
    LIBRARIES gui-core deps::ghostty_vt Qt6::Core Qt6::Gui CHECKS lint lifetime blank_lines)

  target_sources(gui-quick PRIVATE ui/notifications/notification_layout.cpp ui/notifications/notification_layout.hpp)
  target_sources(gui-quick PRIVATE ui/machine_chrome/machine_chrome_layout.cpp ui/machine_chrome/machine_chrome_layout.hpp ui/machine_chrome/machine_chrome_controller.cpp ui/machine_chrome/machine_chrome_controller.hpp)
  set_source_files_properties(ui/machine_chrome/machine_chrome_layout.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  target_sources(gui-quick PRIVATE ui/scene/curve_scene.cpp ui/scene/curve_mask_node.cpp ui/scene/alpha_mask_material.cpp ui/fonts/chrome_fonts.cpp ui/scene/chrome_text_scene.cpp ui/scene/ancestor_geometry.cpp)
  target_sources(gui-quick PRIVATE ui/scene/rounded_rectangle_scene.cpp ui/scene/software_rounded_rectangle.cpp)
  target_sources(gui-quick PRIVATE ui/controls/provider_artwork.cpp ui/fonts/resident_fonts.cpp ui/scene/chrome_icon_scene.cpp)
  target_sources(gui-quick PRIVATE ui/fonts/window_font_catalog.cpp ui/fonts/window_font_catalog.hpp)
  target_sources(gui-quick PRIVATE ui/panes/pane_header_layout.cpp ui/panes/pane_header_layout.hpp ui/controls/chrome_style.hpp)
  target_sources(gui-quick PRIVATE ui/history/history_row_layout.cpp ui/history/history_row_layout.hpp)
  target_sources(gui-quick PRIVATE ui/history/history_match_model.hpp)
  target_sources(gui-quick PRIVATE ui/history/history_meta_layout.cpp ui/history/history_meta_layout.hpp)
  target_sources(gui-quick PRIVATE ui/history/history_footer_layout.cpp ui/history/history_footer_layout.hpp ui/design/history_hint_projection.hpp)
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
  target_sources(gui-quick PRIVATE ui/scene/window_animation_clock.cpp ui/app/window_animation.cpp ui/controls/native_tab_activity.cpp ui/controls/native_tab_activity.hpp ui/controls/native_progress_ring.cpp ui/controls/native_progress_ring.hpp)
  target_sources(gui-quick PRIVATE ui/panes/native_pane_attention.cpp ui/panes/native_pane_attention.hpp)
  set_source_files_properties(ui/panes/native_pane_attention.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  set_source_files_properties(ui/panes/pane_header_layout.cpp ui/app/window_geometry.cpp ui/chrome/sidebar_controller.cpp ui/notifications/notification_layout.cpp ui/scene/window_animation_clock.cpp ui/controls/native_tab_activity.cpp ui/controls/native_progress_ring.cpp ui/controls/native_agent_status.cpp ui/scene/rounded_rectangle_scene.cpp ui/scene/software_rounded_rectangle.cpp ui/controls/native_rounded_rectangle.cpp ui/controls/provider_artwork.cpp ui/scene/chrome_text_scene.cpp ui/scene/chrome_icon_scene.cpp ui/controls/native_chrome_icon.cpp ui/controls/native_cell_text.cpp ui/chrome/native_mode_layout.cpp ui/chrome/tab_strip_layout.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
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
  foreach(folder IN ITEMS activity app attachments chrome components controls design/elements documents history link_status machine_chrome machine_prompt notifications palette panes paths peek prompt store terminal workspaces)
    target_include_directories(gui-quick PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/ui/${folder}")
  endforeach()

  qt_add_qml_module(gui-quick
    URI Telar.Gui
    VERSION 1.0
    OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/Telar/Gui"
    SOURCES ui/attachments/attachment_image.cpp ui/attachments/attachment_image.hpp ui/attachments/attachment_shelf.cpp ui/attachments/attachment_shelf.hpp ui/controls/native_agent_status.cpp ui/controls/native_agent_status.hpp ui/controls/native_rounded_rectangle.cpp ui/controls/native_rounded_rectangle.hpp ui/app/application_controller.cpp ui/app/application_controller.hpp ui/foundation/machines/runtime_connection.cpp ui/foundation/machines/runtime_connection.hpp ui/terminal/terminal_item.cpp ui/terminal/terminal_item.hpp ui/config/configuration_source.cpp ui/config/configuration_source.hpp ui/config/lua_host.cpp ui/config/lua_host.hpp ui/design/elements/element_layout.cpp ui/design/elements/element_layout.hpp ui/design/elements/element_canvas.cpp ui/design/elements/element_canvas.hpp ui/terminal/graphics_scene.cpp ui/terminal/graphics_scene.hpp ui/chrome/tab_strip_layout.cpp ui/chrome/tab_strip_layout.hpp ui/controls/provider_mark.cpp ui/controls/provider_mark.hpp ui/controls/native_chrome_text.cpp ui/controls/native_chrome_text.hpp ui/controls/native_chrome_icon.cpp ui/controls/native_chrome_icon.hpp ui/controls/native_cell_text.cpp ui/controls/native_cell_text.hpp ui/chrome/native_mode_layout.cpp ui/chrome/native_mode_layout.hpp ui/prompt/prompt_editor_item.cpp ui/prompt/prompt_editor_item.hpp ui/documents/document_view.cpp ui/documents/document_view.hpp
    QML_FILES ui/components/ComponentFit.js ui/design/elements/Elements.js ui/design/elements/ElementNode.qml ui/design/elements/ElementHost.qml ui/components/ComponentPick.qml ui/components/ComponentBranch.qml ui/components/ComponentNode.qml ui/components/ComponentTree.qml ui/components/ComponentOverflow.qml ui/components/ComponentSlot.qml ui/components/ComponentPanel.qml ui/attachments/AttachmentShelf.qml ui/attachments/AttachmentModal.qml ui/peek/PeekPanel.qml ui/link_status/LinkStatus.qml ui/machine_chrome/MachineChrome.qml ui/machine_prompt/MachinePromptPanel.qml ui/prompt/PromptPanel.qml ui/design/PromptField.qml ui/design/PromptActions.qml ui/workspaces/WorkspaceFormPanel.qml ui/controls/FormTextField.qml ui/controls/KeyboardAction.qml ui/controls/ActionPointer.qml ui/app/Main.qml ui/controls/DialogSurface.qml ui/chrome/Sidebar.qml ui/chrome/TerminalTabs.qml ui/panes/PaneArea.qml ui/panes/PaneActions.qml ui/panes/PaneHeader.qml ui/panes/FullscreenStrip.qml ui/panes/PaneStatusChip.qml ui/panes/PaneProgress.qml ui/app/CommandDialog.qml ui/paths/PathPickerPanel.qml ui/palette/PalettePanel.qml ui/suggestions/SuggestionPanel.qml ui/palette/PaletteRow.qml ui/design/PaletteKeycap.qml ui/design/PaletteButton.qml ui/history/HistoryPanel.qml ui/history/HistoryKeys.qml ui/paths/PathKeys.qml ui/history/HistoryEmpty.qml ui/history/HistoryInspector.qml ui/controls/FormButton.qml ui/history/HistoryRow.qml ui/history/HistoryMeta.qml ui/design/HistoryHint.qml ui/history/HistoryFooter.qml ui/history/HistoryFilters.qml ui/history/HistoryFilterChip.qml ui/history/HistorySearchBar.qml ui/links/LinkPreview.qml ui/controls/ChromeText.qml ui/controls/ChromeToolTip.qml ui/controls/ChromeIcon.qml ui/controls/ChromeButton.qml ui/controls/ApplicationMark.qml ui/controls/ApplicationTile.qml ui/controls/ElevationShadow.qml ui/workspaces/WorkspaceList.qml ui/workspaces/ProjectRow.qml ui/workspaces/ProjectSwitcher.qml ui/workspaces/WorkspaceIdentity.qml ui/activity/ActivityList.qml ui/activity/ActivityFrame.qml ui/activity/AgentCard.qml ui/activity/AgentStatus.qml ui/activity/TaskCard.qml ui/activity/TaskPlan.qml ui/activity/CommandCard.qml ui/chrome/NavigationBar.qml ui/design/BarBattery.qml ui/design/BarSparkline.qml ui/design/BarMetric.qml ui/design/BarRing.qml ui/design/BarPill.qml ui/design/SystemSummary.qml ui/chrome/MetricsGroup.qml ui/chrome/StatusBar.qml ui/chrome/BarBadge.qml ui/controls/CellText.qml ui/chrome/ModeBar.qml ui/notifications/NotificationOverlay.qml ui/terminal/PromptLine.qml ui/terminal/CommandSeparators.qml ui/terminal/CommandRail.qml ui/terminal/JumpToEnd.qml ui/documents/DocumentView.qml ui/documents/DocumentBlock.qml ui/documents/DocumentTheme.qml ui/documents/InlineDocuments.qml)

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
# telar_gui_scan_moc_imports() does so for the targets of the calling directory.
function(telar_gui_scan_moc_imports)
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
endfunction()

if(BUILD_TESTING)
  add_subdirectory(tests)
endif()
telar_gui_scan_moc_imports()

# The quality checks cover the GUI's libraries and programs; the tests register themselves.
telar_register_checks(gui-core gui-posix CHECKS ${TELAR_CHECKS})
if(TELAR_GUI_NATIVE)
  telar_register_checks(gui-fonts gui-surface-command gui-machine-profiles gui-platform gui-keyboard
    gui-clipboard-images gui-quick telar-gui CHECKS ${TELAR_CHECKS})
  if(APPLE)
    telar_register_checks(telar-gui-launcher CHECKS ${TELAR_CHECKS})
  endif()
endif()

# Probes and smoke tools run by hand or by tools/ scripts, never by CTest: building them on
# every test run costs a full module compile each. `cmake --build out --target gui-probes`
# builds the ones this platform and configuration define.
telar_add_probes(gui-probes)
