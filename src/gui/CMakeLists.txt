telar_process(gui OPTIONS -Wall -Wextra -Wpedantic -ffp-contract=off)

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

# What every domain of the GUI compiles and links with.
target_link_libraries(gui-settings INTERFACE tbc::tbc telar::shell telar::render ebnf::ebnf)
target_include_directories(gui-settings INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/generated")
target_link_libraries(gui-settings INTERFACE telar::config telar::machines gui-harfbuzz deps::ghostty_vt)

# The module domains of docs/build/modules.json (process_layers), lowest first.
foreach(domain IN ITEMS core history layout suggestions text palette peek prompt terminal fonts links
    input attachments paths model platform machines presentation graphics application components
    config transport)
  add_subdirectory(${domain})
endforeach()

add_library(gui-posix STATIC platform/clipboard_image_file.c platform/peer_identity/peer_identity.cpp platform/window_lease/window_lease.cpp platform/profile_file/profile_file.cpp  platform/stdio_socket/stdio_socket.cpp platform/managed_directory/managed_directory.cpp platform/process_group/process_group.cpp)
target_sources(gui-posix PRIVATE platform/clipboard_image_pipe/clipboard_image_pipe.cpp)
target_link_libraries(gui-posix PUBLIC gui-core gui-text gui-attachments gui-platform Threads::Threads)
add_executable(telar-gui-command platform/surface_command_main.c)
target_compile_definitions(telar-gui-command PRIVATE "$<$<PLATFORM_ID:Linux>:_GNU_SOURCE>")
target_compile_options(telar-gui-command PRIVATE -Wall -Wextra -Wpedantic)
target_link_libraries(telar-gui-command PRIVATE telar::build_flags)

add_library(gui-editor-config INTERFACE)
target_link_libraries(gui-editor-config INTERFACE gui-settings deps::ghostty_vt)
target_include_directories(gui-editor-config INTERFACE "${CMAKE_CURRENT_BINARY_DIR}/generated")

file(GENERATE
  OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/clangd/config/compile_flags.txt"
  CONTENT "-xc++\n-std=c++${CMAKE_CXX_STANDARD}\n-I$<JOIN:$<REMOVE_DUPLICATES:$<TARGET_PROPERTY:gui-editor-config,INTERFACE_INCLUDE_DIRECTORIES>>,\n-I>\n-D$<JOIN:$<TARGET_PROPERTY:gui-editor-config,INTERFACE_COMPILE_DEFINITIONS>,\n-D>\n")

add_custom_target(gui-editor)
add_library(gui-editor-context INTERFACE)
target_link_libraries(gui-editor-context INTERFACE gui-editor-config)
file(GENERATE
  OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/clangd/domain/compile_flags.txt"
  CONTENT "-xc++\n-std=c++${CMAKE_CXX_STANDARD}\n-I$<JOIN:$<REMOVE_DUPLICATES:$<TARGET_PROPERTY:gui-editor-context,INTERFACE_INCLUDE_DIRECTORIES>>,\n-I>\n-D$<JOIN:$<TARGET_PROPERTY:gui-editor-context,INTERFACE_COMPILE_DEFINITIONS>,\n-D>\n")

if(TELAR_GUI_NATIVE)
  # The fonts domain's faces and shaping, which only the native window uses.
  add_library(gui-fonts-native STATIC fonts/face/face.cpp fonts/face/ligature_coverage.cpp fonts/font_requests/font_requests.cpp fonts/row_text_layout/row_text_layout.cpp)
  target_link_libraries(gui-fonts-native PUBLIC gui-core gui-terminal gui-fonts gui-harfbuzz)
  target_link_libraries(gui-editor-context INTERFACE gui-fonts-native)
  target_compile_options(gui-fonts-native PRIVATE -ffp-contract=off)

  include(cmake/qt.cmake)
  find_package(Qt6 ${TELAR_QT_VERSION} EXACT REQUIRED COMPONENTS Gui Qml Quick QuickControls2 Network Concurrent ShaderTools Svg
    PATHS "${TELAR_GUI_QT_PREFIX}/lib/cmake/Qt6" NO_DEFAULT_PATH)
  find_package(Qt6GuiPrivate ${TELAR_QT_VERSION} EXACT REQUIRED CONFIG
    PATHS "${TELAR_GUI_QT_PREFIX}/lib/cmake/Qt6GuiPrivate" NO_DEFAULT_PATH)
  qt_standard_project_setup(REQUIRES 6.7)
  add_library(gui-surface-command STATIC ui/app/chrome/components/surface_command.cpp)
  target_link_libraries(gui-surface-command PUBLIC gui-posix gui-platform Qt6::Core)
  add_dependencies(gui-surface-command telar-gui-command)

  add_library(gui-machine-profiles STATIC ui/app/overlays/machine_prompt/machine_profiles_source.cpp ui/app/overlays/machine_prompt/machine_profiles_source.hpp)
  target_link_libraries(gui-machine-profiles PUBLIC gui-posix gui-platform gui-machines Qt6::Concurrent)
  if(Qt6_VERSION VERSION_GREATER_EQUAL 6.8)
    qt_policy(SET QTP0004 NEW)
  endif()

  # The platform domain's native window, fonts and clipboard images, on Qt.
  add_library(gui-platform-native STATIC platform/login_shell/host_name.cpp)
  target_link_libraries(gui-platform-native PUBLIC gui-fonts gui-platform gui-posix Qt6::Gui PRIVATE Qt6::Quick)
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
    target_sources(gui-platform-native PRIVATE platform/macos/window.mm platform/macos/blur_symbols.m platform/macos/text_input.mm platform/macos/scroll_event.mm platform/macos/clipboard_image_source.mm)
    target_sources(gui-platform-native PRIVATE platform/macos/font.mm platform/macos/glyph_rasterizer.mm fonts/glyph_rasterizer/glyph_rasterizer.cpp)
    target_sources(gui-platform-native PRIVATE platform/macos/optical_text.mm)
    target_link_libraries(gui-platform-native PRIVATE Qt6::GuiPrivate)
    target_compile_options(gui-platform-native PRIVATE "$<$<COMPILE_LANGUAGE:OBJC,OBJCXX>:-fobjc-arc>")
    if(TELAR_GUI_HAS_OBJC_CLASS_STUB_CONTROL)
      target_compile_options(gui-platform-native PRIVATE "$<$<COMPILE_LANGUAGE:OBJC,OBJCXX>:-fno-objc-msgsend-class-selector-stubs>")
    endif()

    target_link_libraries(gui-platform-native PRIVATE "-framework AppKit" "-framework CoreText" "-framework CoreGraphics" "-framework ImageIO")
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
    target_sources(gui-platform-native PRIVATE platform/background_effect/background_effect.cpp
      platform/linux/background_effect.c "${GUI_BACKGROUND_EFFECT_HEADER}" "${GUI_BACKGROUND_EFFECT_CODE}")
    target_include_directories(gui-platform-native PRIVATE "${GUI_BACKGROUND_EFFECT_DIR}")
    target_link_libraries(gui-platform-native PRIVATE Qt6::WaylandClientPrivate PkgConfig::GUI_WAYLAND_CLIENT PkgConfig::GUI_XCB)
    target_link_libraries(gui-platform-native PRIVATE Fontconfig::Fontconfig)
    target_sources(gui-platform-native PRIVATE platform/linux/font.c)
    target_sources(gui-platform-native PRIVATE platform/linux/window.cpp platform/linux/clipboard_image_source.cpp platform/linux/clipboard_image_monitor.cpp platform/linux/xcb_clipboard_image_monitor.cpp platform/linux/wayland_clipboard_image_monitor.cpp)
    target_sources(gui-platform-native PRIVATE ui/foundation/scene/optical_text_fallback.cpp)
  else()
    message(FATAL_ERROR "The GUI supports macOS and Linux")
  endif()

  add_library(gui-keyboard STATIC ui/foundation/input/terminal_input.cpp)
  # It imports no domain; the lowest, gui-core, gives it the GUI's settings.
  target_link_libraries(gui-keyboard PUBLIC gui-core Qt6::Gui)

  add_library(gui-clipboard-images STATIC ui/app/panes/attachments/attachment_preview.cpp ui/app/panes/attachments/attachment_preview.hpp ui/app/panes/attachments/clipboard_images.cpp ui/app/panes/attachments/clipboard_images.hpp)
  target_link_libraries(gui-clipboard-images PUBLIC gui-platform-native gui-attachments gui-machines gui-graphics Qt6::Concurrent)

  qt_add_library(gui-quick STATIC)
  target_link_libraries(gui-quick PRIVATE Qt6::GuiPrivate)
  target_sources(gui-quick PRIVATE ui/app/panes/terminal/window_images.cpp ui/app/panes/terminal/image_resource.cpp)
  target_link_libraries(gui-quick PUBLIC gui-clipboard-images)
  set_source_files_properties(ui/app/panes/attachments/attachment_preview.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")

  target_sources(gui-quick PRIVATE ui/app/panes/terminal/terminal_scene.cpp ui/app/panes/terminal/terminal_scene.hpp)
  target_sources(gui-quick PRIVATE ui/foundation/scene/text_scene.cpp)
  target_sources(gui-quick PRIVATE ui/foundation/fonts/font_source.cpp ui/foundation/fonts/font_resolver.cpp)
  target_sources(gui-quick PRIVATE ui/foundation/fonts/bundled_fonts.cpp ui/foundation/fonts/terminal_font.cpp platform/runtime_endpoint/runtime_endpoint.cpp platform/login_shell/login_shell.cpp)
  target_link_libraries(gui-quick PUBLIC gui-core gui-history gui-layout gui-suggestions gui-text gui-palette
    gui-peek gui-prompt gui-terminal gui-fonts gui-links gui-input gui-attachments gui-paths gui-model
    gui-platform gui-machines gui-presentation gui-graphics gui-application gui-components gui-config
    gui-transport gui-platform-native gui-keyboard gui-fonts-native gui-machine-profiles Qt6::Quick
    Qt6::QuickControls2 Qt6::Network Qt6::Concurrent)
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

  target_sources(gui-quick PRIVATE ui/app/panes/attachments/attachments_controller.cpp ui/app/panes/attachments/attachments_controller.hpp ui/app/plugin_commands.cpp ui/foundation/plugins/plugin_runner.cpp ui/foundation/plugins/plugin_runner.hpp ui/app/prompt_commands.cpp ui/app/panes/terminal/prompt/prompt_controller.cpp ui/app/panes/terminal/prompt/prompt_controller.hpp ui/app/panes/documents/documents_controller.cpp ui/app/panes/documents/documents_controller.hpp)
  target_sources(gui-quick PRIVATE ui/app/chrome/components/components_controller.cpp ui/app/chrome/components/components_controller.hpp ui/app/component_commands.cpp ui/app/element_commands.cpp ui/design/elements/element_slots.cpp ui/design/elements/element_slots.hpp)
  target_link_libraries(gui-quick PRIVATE gui-surface-command Qt6::Svg)
  target_sources(gui-quick PRIVATE ui/app/panes/terminal/history/history_controller.cpp ui/app/panes/terminal/history/history_controller.hpp ui/app/panes/terminal/history/history_pointer.cpp ui/app/binding_commands.cpp ui/app/key_bindings.cpp ui/app/panes/terminal/copy_controller.cpp ui/app/panes/terminal/copy_controller.hpp ui/app/panes/terminal/terminal_controller.cpp ui/app/panes/terminal/terminal_controller.hpp ui/app/panes/terminal/terminal_host.hpp ui/app/terminal_host.cpp ui/foundation/links/links_controller.cpp ui/foundation/links/links_controller.hpp)
  target_sources(gui-quick PRIVATE ui/app/palette_commands.cpp ui/app/panes/terminal/paths/path_picker_controller.cpp ui/app/panes/terminal/paths/path_picker_controller.hpp ui/app/panes/terminal/paths/path_picker_projection.cpp ui/app/overlays/workspace_form/workspace_form_controller.cpp ui/app/overlays/workspace_form/workspace_form_controller.hpp)
  target_sources(gui-quick PRIVATE ui/app/machine_clients.cpp ui/app/machine_profiles.cpp ui/app/machine_actions.cpp ui/app/overlays/machine_prompt/machine_prompt_controller.cpp ui/app/overlays/machine_prompt/machine_prompt_controller.hpp ui/app/machine_launch.cpp ui/app/activity_selection.cpp)
  target_sources(gui-quick PRIVATE ui/foundation/store/store.cpp ui/foundation/store/store.hpp)
  target_sources(gui-quick PRIVATE ui/foundation/input/window_actions.hpp)
  target_sources(gui-quick PRIVATE ui/app/chrome/workspaces/workspaces_controller.cpp ui/app/chrome/workspaces/workspaces_controller.hpp ui/app/chrome/tabs_controller.cpp ui/app/chrome/tabs_controller.hpp ui/app/chrome/sidebar_controller.cpp ui/app/chrome/sidebar_controller.hpp ui/app/panes/panes_controller.cpp ui/app/panes/panes_controller.hpp ui/app/chrome/activity/activity_controller.cpp ui/app/chrome/activity/activity_controller.hpp ui/foundation/models/machine_activity_target.cpp ui/foundation/models/machine_activity_target.hpp ui/app/overlays/palette/palette_controller.cpp ui/app/overlays/palette/palette_controller.hpp)
  target_sources(gui-quick PRIVATE ui/app/overlays/peek/peek_controller.cpp ui/app/overlays/peek/peek_controller.hpp ui/app/overlays/link_status/link_status_controller.cpp ui/app/overlays/link_status/link_status_controller.hpp)
  set_source_files_properties(ui/app/overlays/palette/palette_controller.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  target_sources(gui-quick PRIVATE ui/app/panes/terminal/history/history_empty_layout.cpp ui/app/panes/terminal/history/history_empty_layout.hpp ui/app/panes/terminal/history/history_loading_layout.cpp ui/app/panes/terminal/history/history_loading_layout.hpp ui/app/panes/terminal/history/history_selection_layout.cpp ui/app/panes/terminal/history/history_selection_layout.hpp)
  target_sources(gui-quick PRIVATE ui/design/controls/modal_reveal_layout.cpp ui/design/controls/modal_reveal_layout.hpp)
  target_sources(gui-quick PRIVATE ui/app/panes/pane_motion_layout.cpp ui/app/panes/pane_motion_layout.hpp)
  set_source_files_properties(ui/design/controls/modal_reveal_layout.cpp ui/app/panes/pane_motion_layout.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  set_source_files_properties(ui/app/panes/terminal/history/history_empty_layout.cpp ui/app/panes/terminal/history/history_loading_layout.cpp ui/app/panes/terminal/history/history_selection_layout.cpp ui/app/panes/terminal/history/history_row_layout.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  target_sources(gui-quick PRIVATE ui/app/panes/terminal/terminal_pointer.cpp ui/app/panes/terminal/terminal_scroll.cpp ui/app/panes/terminal/terminal_links.cpp ui/app/panes/terminal/links/link_preview.cpp ui/app/pointer_dispatcher.cpp ui/foundation/input/native_pointer_events.cpp)
  target_sources(gui-quick PRIVATE ui/foundation/config/configuration_loader.cpp)
  target_sources(gui-quick PRIVATE ui/app/notification_commands.cpp ui/app/graphics_recovery.cpp ui/app/overlays/notifications/notifications_controller.cpp ui/app/overlays/notifications/notifications_controller.hpp ui/app/window_geometry.cpp ui/app/application_effects.cpp ui/foundation/machines/machine_effects.cpp ui/foundation/machines/machine_effects.hpp)
  add_custom_target(gui-editor-ui
    COMMAND Python3::Interpreter "${CMAKE_CURRENT_SOURCE_DIR}/tools/create_editor_database.py" --build-dir "${CMAKE_BINARY_DIR}"
    DEPENDS tools/create_editor_database.py
    VERBATIM)
  add_dependencies(gui-editor gui-editor-ui)
  # Run by hand by tools/check_notification_desktop.py, so a tree configured without
  # tests builds it too.
  telar_add_test(gui-host-effects-smoke QT PROBE SOURCES tools/host_effects_smoke.cpp
    LIBRARIES gui-core gui-history gui-layout gui-text gui-model gui-platform gui-presentation gui-application
      deps::ghostty_vt Qt6::Core Qt6::Gui CHECKS lint lifetime blank_lines)

  target_sources(gui-quick PRIVATE ui/app/overlays/notifications/notification_layout.cpp ui/app/overlays/notifications/notification_layout.hpp)
  target_sources(gui-quick PRIVATE ui/app/chrome/components/machine_chrome/machine_chrome_layout.cpp ui/app/chrome/components/machine_chrome/machine_chrome_layout.hpp ui/app/chrome/components/machine_chrome/machine_chrome_controller.cpp ui/app/chrome/components/machine_chrome/machine_chrome_controller.hpp)
  set_source_files_properties(ui/app/chrome/components/machine_chrome/machine_chrome_layout.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  target_sources(gui-quick PRIVATE ui/foundation/scene/curve_scene.cpp ui/foundation/scene/curve_mask_node.cpp ui/foundation/scene/alpha_mask_material.cpp ui/foundation/fonts/chrome_fonts.cpp ui/foundation/scene/chrome_text_scene.cpp ui/foundation/scene/ancestor_geometry.cpp)
  target_sources(gui-quick PRIVATE ui/foundation/scene/rounded_rectangle_scene.cpp ui/foundation/scene/software_rounded_rectangle.cpp)
  target_sources(gui-quick PRIVATE ui/design/controls/provider_artwork.cpp ui/foundation/fonts/resident_fonts.cpp ui/foundation/scene/chrome_icon_scene.cpp)
  target_sources(gui-quick PRIVATE ui/foundation/fonts/window_font_catalog.cpp ui/foundation/fonts/window_font_catalog.hpp)
  target_sources(gui-quick PRIVATE ui/app/panes/pane_header_layout.cpp ui/app/panes/pane_header_layout.hpp ui/design/controls/chrome_style.hpp)
  target_sources(gui-quick PRIVATE ui/app/panes/terminal/history/history_row_layout.cpp ui/app/panes/terminal/history/history_row_layout.hpp)
  target_sources(gui-quick PRIVATE ui/app/panes/terminal/history/history_match_model.hpp)
  target_sources(gui-quick PRIVATE ui/app/panes/terminal/history/history_meta_layout.cpp ui/app/panes/terminal/history/history_meta_layout.hpp)
  target_sources(gui-quick PRIVATE ui/app/panes/terminal/history/history_footer_layout.cpp ui/app/panes/terminal/history/history_footer_layout.hpp ui/design/history_hint_projection.hpp)
  target_sources(gui-quick PRIVATE ui/app/panes/terminal/history/history_filters_layout.cpp ui/app/panes/terminal/history/history_filters_layout.hpp)
  target_sources(gui-quick PRIVATE ui/app/panes/terminal/history/history_inspection_layout.cpp ui/app/panes/terminal/history/history_inspection_layout.hpp)
  target_sources(gui-quick PRIVATE ui/design/controls/native_form_field.cpp ui/design/controls/native_form_field_input.cpp ui/design/controls/native_form_field.hpp ui/design/controls/form_composition_events.cpp)
  set_source_files_properties(ui/design/controls/native_form_field.cpp ui/design/controls/native_form_field_input.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  set_source_files_properties(ui/app/panes/terminal/history/history_filters_layout.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  set_source_files_properties(ui/app/panes/terminal/history/history_footer_layout.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  set_source_files_properties(ui/app/panes/terminal/history/history_meta_layout.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  set_source_files_properties(ui/app/panes/terminal/history/history_row_layout.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  target_sources(gui-quick PRIVATE ui/app/panes/fullscreen_strip_layout.cpp ui/app/panes/fullscreen_strip_layout.hpp)
  set_source_files_properties(ui/app/panes/fullscreen_strip_layout.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  target_sources(gui-quick PRIVATE ui/foundation/scene/window_animation_clock.cpp ui/app/window_animation.cpp ui/design/controls/native_tab_activity.cpp ui/design/controls/native_tab_activity.hpp ui/design/controls/native_progress_ring.cpp ui/design/controls/native_progress_ring.hpp)
  target_sources(gui-quick PRIVATE ui/app/panes/native_pane_attention.cpp ui/app/panes/native_pane_attention.hpp)
  set_source_files_properties(ui/app/panes/native_pane_attention.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  set_source_files_properties(ui/app/panes/pane_header_layout.cpp ui/app/window_geometry.cpp ui/app/chrome/sidebar_controller.cpp ui/app/overlays/notifications/notification_layout.cpp ui/foundation/scene/window_animation_clock.cpp ui/design/controls/native_tab_activity.cpp ui/design/controls/native_progress_ring.cpp ui/design/controls/native_agent_status.cpp ui/foundation/scene/rounded_rectangle_scene.cpp ui/foundation/scene/software_rounded_rectangle.cpp ui/design/controls/native_rounded_rectangle.cpp ui/design/controls/provider_artwork.cpp ui/foundation/scene/chrome_text_scene.cpp ui/foundation/scene/chrome_icon_scene.cpp ui/design/controls/native_chrome_icon.cpp ui/design/controls/native_cell_text.cpp ui/app/chrome/native_mode_layout.cpp ui/app/chrome/tab_strip_layout.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  qt_add_shaders(gui-quick gui-curve-shaders
    PREFIX "/telar/shaders"
    BASE "${CMAKE_CURRENT_SOURCE_DIR}/ui/foundation/scene/shaders"
    BATCHABLE
    FILES ui/foundation/scene/shaders/alpha_mask.vert ui/foundation/scene/shaders/alpha_mask.frag ui/foundation/scene/shaders/nearest_alpha_mask.frag ui/foundation/scene/shaders/filtered_alpha_mask.frag ui/foundation/scene/shaders/tab_caption.frag)

  qt_add_shaders(gui-quick gui-shape-shaders
    PREFIX "/telar/shaders"
    BASE "${CMAKE_CURRENT_SOURCE_DIR}/ui/foundation/scene/shaders"
    BATCHABLE
    PERTARGETCOMPILE
    FILES ui/foundation/scene/shaders/rounded_rectangle.vert ui/foundation/scene/shaders/rounded_rectangle.frag)

  qt_add_shaders(gui-quick gui-straight-mask-shaders
    PREFIX "/telar/shaders"
    BASE "${CMAKE_CURRENT_SOURCE_DIR}/ui/foundation/scene/shaders"
    BATCHABLE
    DEFINES TELAR_STRAIGHT_ALPHA=1
    OUTPUTS straight/alpha_mask.frag.qsb straight/nearest_alpha_mask.frag.qsb straight/filtered_alpha_mask.frag.qsb
    FILES ui/foundation/scene/shaders/alpha_mask.frag ui/foundation/scene/shaders/nearest_alpha_mask.frag ui/foundation/scene/shaders/filtered_alpha_mask.frag)

  set_source_files_properties(ui/app/chrome/components/ComponentFit.js PROPERTIES QT_QML_SKIP_QMLDIR_ENTRY TRUE)

  # The generated QML type registrations include each registered header by its bare name.
  # Sources spell ui/ headers from src/gui; only the registrations need these folders.
  foreach(folder IN ITEMS app/chrome/activity app app/panes/attachments app/chrome app/chrome/components design/controls design/elements app/panes/documents app/panes/terminal/history app/overlays/link_status app/chrome/components/machine_chrome app/overlays/machine_prompt app/overlays/notifications app/overlays/palette app/panes app/panes/terminal/paths app/overlays/peek app/panes/terminal/prompt foundation/store app/panes/terminal app/overlays/workspace_form app/chrome/workspaces)
    target_include_directories(gui-quick PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/ui/${folder}")
  endforeach()

  qt_add_qml_module(gui-quick
    URI Telar.Gui
    VERSION 1.0
    OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/Telar/Gui"
    SOURCES ui/app/panes/attachments/attachment_image.cpp ui/app/panes/attachments/attachment_image.hpp ui/app/panes/attachments/attachment_shelf.cpp ui/app/panes/attachments/attachment_shelf.hpp ui/design/controls/native_agent_status.cpp ui/design/controls/native_agent_status.hpp ui/design/controls/native_rounded_rectangle.cpp ui/design/controls/native_rounded_rectangle.hpp ui/app/application_controller.cpp ui/app/application_controller.hpp ui/foundation/machines/runtime_connection.cpp ui/foundation/machines/runtime_connection.hpp ui/app/panes/terminal/terminal_item.cpp ui/app/panes/terminal/terminal_item.hpp ui/foundation/config/configuration_source.cpp ui/foundation/config/configuration_source.hpp ui/foundation/config/lua_host.cpp ui/foundation/config/lua_host.hpp ui/design/elements/element_layout.cpp ui/design/elements/element_layout.hpp ui/design/elements/element_canvas.cpp ui/design/elements/element_canvas.hpp ui/app/panes/terminal/graphics_scene.cpp ui/app/panes/terminal/graphics_scene.hpp ui/app/chrome/tab_strip_layout.cpp ui/app/chrome/tab_strip_layout.hpp ui/design/controls/provider_mark.cpp ui/design/controls/provider_mark.hpp ui/design/controls/native_chrome_text.cpp ui/design/controls/native_chrome_text.hpp ui/design/controls/native_chrome_icon.cpp ui/design/controls/native_chrome_icon.hpp ui/design/controls/native_cell_text.cpp ui/design/controls/native_cell_text.hpp ui/app/chrome/native_mode_layout.cpp ui/app/chrome/native_mode_layout.hpp ui/app/panes/terminal/prompt/prompt_editor_item.cpp ui/app/panes/terminal/prompt/prompt_editor_item.hpp ui/app/panes/documents/document_view.cpp ui/app/panes/documents/document_view.hpp
    QML_FILES ui/app/chrome/components/ComponentFit.js ui/design/elements/Elements.js ui/design/elements/ElementNode.qml ui/design/elements/ElementHost.qml ui/app/chrome/components/ComponentPick.qml ui/app/chrome/components/ComponentBranch.qml ui/app/chrome/components/ComponentNode.qml ui/app/chrome/components/ComponentTree.qml ui/app/chrome/components/ComponentOverflow.qml ui/app/chrome/components/ComponentSlot.qml ui/app/chrome/components/ComponentPanel.qml ui/app/panes/attachments/AttachmentShelf.qml ui/app/panes/attachments/AttachmentModal.qml ui/app/overlays/peek/PeekPanel.qml ui/app/overlays/link_status/LinkStatus.qml ui/app/chrome/components/machine_chrome/MachineChrome.qml ui/app/overlays/machine_prompt/MachinePromptPanel.qml ui/app/overlays/prompt_panel/PromptPanel.qml ui/design/PromptField.qml ui/design/PromptActions.qml ui/app/overlays/workspace_form/WorkspaceFormPanel.qml ui/design/controls/FormTextField.qml ui/design/controls/KeyboardAction.qml ui/design/controls/ActionPointer.qml ui/app/Main.qml ui/design/controls/DialogSurface.qml ui/app/chrome/Sidebar.qml ui/app/chrome/TerminalTabs.qml ui/app/panes/PaneArea.qml ui/app/panes/PaneActions.qml ui/app/panes/PaneHeader.qml ui/app/panes/FullscreenStrip.qml ui/app/panes/PaneStatusChip.qml ui/app/panes/PaneProgress.qml ui/app/CommandDialog.qml ui/app/panes/terminal/paths/PathPickerPanel.qml ui/app/overlays/palette/PalettePanel.qml ui/app/overlays/palette/suggestions/SuggestionPanel.qml ui/app/overlays/palette/PaletteRow.qml ui/design/PaletteKeycap.qml ui/design/PaletteButton.qml ui/app/panes/terminal/history/HistoryPanel.qml ui/app/panes/terminal/history/HistoryKeys.qml ui/app/panes/terminal/paths/PathKeys.qml ui/app/panes/terminal/history/HistoryEmpty.qml ui/app/panes/terminal/history/HistoryInspector.qml ui/design/controls/FormButton.qml ui/app/panes/terminal/history/HistoryRow.qml ui/app/panes/terminal/history/HistoryMeta.qml ui/design/HistoryHint.qml ui/app/panes/terminal/history/HistoryFooter.qml ui/app/panes/terminal/history/HistoryFilters.qml ui/app/panes/terminal/history/HistoryFilterChip.qml ui/app/panes/terminal/history/HistorySearchBar.qml ui/app/panes/terminal/links/LinkPreview.qml ui/design/controls/ChromeText.qml ui/design/controls/ChromeToolTip.qml ui/design/controls/ChromeIcon.qml ui/design/controls/ChromeButton.qml ui/design/controls/ApplicationMark.qml ui/design/controls/ApplicationTile.qml ui/design/controls/ElevationShadow.qml ui/app/chrome/workspaces/WorkspaceList.qml ui/app/chrome/workspaces/ProjectRow.qml ui/app/chrome/workspaces/ProjectSwitcher.qml ui/app/chrome/workspaces/WorkspaceIdentity.qml ui/app/chrome/activity/ActivityList.qml ui/app/chrome/activity/ActivityFrame.qml ui/app/chrome/activity/AgentCard.qml ui/app/chrome/activity/AgentStatus.qml ui/app/chrome/activity/TaskCard.qml ui/app/chrome/activity/TaskPlan.qml ui/app/chrome/activity/CommandCard.qml ui/app/chrome/NavigationBar.qml ui/design/BarBattery.qml ui/design/BarSparkline.qml ui/design/BarMetric.qml ui/design/BarRing.qml ui/design/BarPill.qml ui/design/SystemSummary.qml ui/app/chrome/MetricsGroup.qml ui/app/chrome/StatusBar.qml ui/app/chrome/BarBadge.qml ui/design/controls/CellText.qml ui/app/chrome/ModeBar.qml ui/app/overlays/notifications/NotificationOverlay.qml ui/app/panes/terminal/PromptLine.qml ui/app/panes/terminal/CommandSeparators.qml ui/app/panes/terminal/CommandRail.qml ui/app/panes/terminal/JumpToEnd.qml ui/app/panes/documents/DocumentView.qml ui/app/panes/documents/DocumentBlock.qml ui/app/panes/documents/DocumentTheme.qml ui/app/panes/documents/InlineDocuments.qml)

  qt_add_executable(telar-gui main.cpp)
  if(APPLE)
    target_link_options(telar-gui PRIVATE -Wl,-headerpad_max_install_names)
    add_executable(telar-gui-launcher tools/macos_launcher.cpp platform/login_shell/login_shell.cpp)
    target_link_libraries(telar-gui-launcher PRIVATE gui-platform)
    target_compile_options(telar-gui-launcher PRIVATE -Wall -Wextra -Werror)
    target_link_options(telar-gui-launcher PRIVATE -Wl,-headerpad_max_install_names)
    set_target_properties(telar-gui-launcher PROPERTIES AUTOMOC OFF AUTOUIC OFF AUTORCC OFF)
    add_dependencies(telar-gui telar-gui-launcher)
  endif()
  target_link_libraries(telar-gui PRIVATE gui-platform gui-machines gui-quick gui-quickplugin)
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
telar_register_checks(gui-posix CHECKS ${TELAR_CHECKS})
if(TELAR_GUI_NATIVE)
  telar_register_checks(gui-fonts-native gui-surface-command gui-machine-profiles gui-platform-native gui-keyboard
    gui-clipboard-images gui-quick telar-gui CHECKS ${TELAR_CHECKS})
  if(APPLE)
    telar_register_checks(telar-gui-launcher CHECKS ${TELAR_CHECKS})
  endif()
endif()

# Probes and smoke tools run by hand or by tools/ scripts, never by CTest: building them on
# every test run costs a full module compile each. `cmake --build out --target gui-probes`
# builds the ones this platform and configuration define.
telar_add_probes(gui-probes)
