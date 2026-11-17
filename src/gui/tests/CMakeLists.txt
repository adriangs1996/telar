# The test programs, probes and test libraries of the GUI. The tests of the domains and of
# the libraries below Qt build without Qt's code generators, which qt_standard_project_setup
# turns on for the GUI. The probes and tools under tools/ are also checked for lifetimes.
set(CMAKE_AUTOMOC OFF)
set(CMAKE_AUTOUIC OFF)

# Shared test fixtures are module interfaces. They link the domains they import, whose
# -ffp-contract=off they inherit like every other GUI importer.
file(GLOB gui_test_fixtures CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/*/*.cppm")
list(REMOVE_ITEM gui_test_fixtures "${CMAKE_CURRENT_SOURCE_DIR}/font_fixture/font_fixture.cppm")
telar_add_test(gui-test-fixtures STATIC SOURCES ${gui_test_fixtures} LIBRARIES gui-foundation-actions gui-foundation-core gui-foundation-system gui-foundation-fonts gui-platform gui-application gui-features-plugins)

telar_add_test(gui-session-effects-test SOURCES session_effects_test.cpp LIBRARIES gui-foundation-core gui-foundation-system gui-platform gui-application gui-test-fixtures
  TEST gui-session-effects LABELS gui.application)

telar_add_test(gui-clipboard-image-pipe-test SOURCES clipboard_image_pipe_test.cpp platform/clipboard_pipe_status.c LIBRARIES gui-posix gui-test-fixtures gui-platform
  TEST gui-clipboard-image-pipe LABELS gui.platform TIMEOUT 20)

telar_add_test(gui-attachment-capture-test SOURCES attachment_capture_test.cpp LIBRARIES gui-features-terminal-attachments
  TEST gui-attachment-capture LABELS gui.features.terminal.attachments)

telar_add_test(gui-attachment-catalog-test SOURCES attachment_catalog_test.cpp LIBRARIES gui-features-terminal-attachments gui-test-fixtures
  TEST gui-attachment-catalog LABELS gui.features.terminal.attachments)

telar_add_test(gui-attachment-marker-test SOURCES attachment_marker_test.cpp LIBRARIES gui-features-terminal-attachments
  TEST gui-attachment-marker LABELS gui.features.terminal.attachments)

telar_add_test(gui-attachment-layout-test SOURCES attachment_layout_test.cpp LIBRARIES gui-foundation-model gui-foundation-core
  TEST gui-attachment-layout LABELS gui.foundation.model)

telar_add_test(gui-host-commands-test SOURCES host_commands_test.cpp LIBRARIES gui-foundation-system gui-platform
  TEST gui-host-commands LABELS gui.platform)

telar_add_test(gui-agent-acknowledgement-test SOURCES agent_acknowledgement_test.cpp LIBRARIES gui-application gui-test-fixtures
  TEST gui-agent-acknowledgement LABELS gui.application)

telar_add_test(gui-display-metrics-test SOURCES display_metrics_test.cpp LIBRARIES gui-foundation-core gui-features-activity gui-features-workbench gui-features-window
  TEST gui-display-metrics LABELS gui.features.window)
target_compile_options(gui-display-metrics-test PRIVATE -ffp-contract=off)

telar_add_test(gui-agent-alerts-test SOURCES agent_alerts_test.cpp LIBRARIES gui-foundation-model gui-application
  TEST gui-agent-alerts LABELS gui.foundation.model)

telar_add_test(gui-notification-center-test SOURCES notification_center_test.cpp LIBRARIES gui-application
  TEST gui-notification-center LABELS gui.features.notifications)
target_compile_options(gui-notification-center-test PRIVATE -ffp-contract=off)

telar_add_test(gui-notification-text-test SOURCES notification_text_test.cpp LIBRARIES gui-foundation-text gui-foundation-system gui-features-notifications deps::ghostty_vt
  TEST gui-notification-text LABELS gui.features.notifications)

telar_add_test(gui-notification-stack-test SOURCES notification_stack_test.cpp LIBRARIES gui-foundation-core gui-application
  TEST gui-notification-stack LABELS gui.features.notifications)
target_compile_options(gui-notification-stack-test PRIVATE -ffp-contract=off)

telar_add_test(gui-graphics-retention-test SOURCES graphics_retention_test.cpp LIBRARIES gui-features-terminal-graphics
  TEST gui-graphics-retention LABELS gui.features.terminal.graphics)
telar_add_test(gui-image-residency-test SOURCES image_residency_test.cpp LIBRARIES gui-features-terminal-graphics
  TEST gui-image-residency LABELS gui.features.terminal.graphics)
telar_add_test(gui-graphics-recovery-test SOURCES graphics_recovery_test.cpp LIBRARIES gui-features-terminal-graphics gui-application gui-test-fixtures
  TEST gui-graphics-recovery LABELS gui.features.terminal.graphics)
telar_add_test(gui-shared-image-test SOURCES shared_image_test.cpp LIBRARIES gui-foundation-system gui-posix gui-test-fixtures gui-platform gui-features-terminal-graphics gui-application
  TEST gui-shared-image LABELS gui.platform)

telar_add_test(gui-session-notifications-test SOURCES session_notifications_test.cpp LIBRARIES gui-application gui-test-fixtures
  TEST gui-session-notifications LABELS gui.application)

telar_add_test(gui-notification-actions-test SOURCES notification_actions_test.cpp LIBRARIES gui-foundation-actions gui-application
  TEST gui-notification-actions LABELS gui.foundation.actions)

telar_add_test(gui-notification-effects-test SOURCES notification_effects_test.cpp LIBRARIES gui-foundation-system gui-application
  TEST gui-notification-effects LABELS gui.application)

telar_add_test(gui-pane-creation-test SOURCES pane_creation_test.cpp LIBRARIES gui-foundation-model gui-application gui-test-fixtures
  TEST gui-pane-creation LABELS gui.application)
telar_add_test(gui-command-tab-test SOURCES command_tab_test.cpp LIBRARIES gui-foundation-actions gui-application gui-test-fixtures
  TEST gui-command-tab LABELS gui.features.configuration)
telar_add_test(gui-binding-query-test SOURCES binding_query_test.cpp LIBRARIES gui-features-configuration gui-test-fixtures
  TEST gui-binding-query LABELS gui.features.configuration)
telar_add_test(gui-theme-test SOURCES theme_test.cpp LIBRARIES gui-foundation-core gui-application
  TEST gui-theme LABELS gui.features.configuration)
telar_add_test(gui-config-query-test SOURCES configuration_query_test.cpp LIBRARIES gui-features-configuration gui-features-status_bar gui-foundation-actions gui-foundation-keys gui-foundation-core gui-test-fixtures
  TEST gui-config-query LABELS gui.features.configuration)
telar_add_test(gui-presentation-test SOURCES presentation_test.cpp LIBRARIES gui-foundation-model gui-foundation-core gui-foundation-text gui-features-terminal-graphics gui-application
  TEST LABELS gui.application)
telar_add_test(gui-text-fit-test SOURCES text_fit_test.cpp LIBRARIES gui-foundation-text gui-foundation-system deps::ghostty_vt gui-test-fixtures
  TEST gui-text-fit LABELS gui.foundation.text)
target_compile_options(gui-text-fit-test PRIVATE -ffp-contract=off)
telar_add_test(gui-font-grid-test SOURCES font_grid_test.cpp LIBRARIES gui-foundation-core gui-foundation-terminal gui-test-fixtures
  TEST gui-font-grid LABELS gui.foundation.terminal)
telar_add_test(gui-core-test SOURCES core_test.cpp LIBRARIES gui-foundation-model gui-foundation-core gui-foundation-terminal gui-features-history gui-features-terminal-input gui-application gui-test-fixtures
  TEST LABELS gui.foundation.core TIMEOUT 30)
telar_add_test(gui-color-test SOURCES color_test.cpp LIBRARIES gui-foundation-core
  TEST gui-color LABELS gui.foundation.core)
telar_add_test(gui-screen-probe PROBE SOURCES ${TELAR_PROCESS_SOURCE_DIR}/tools/screen_probe.cpp LIBRARIES gui-foundation-core gui-foundation-terminal
  CHECKS lint lifetime blank_lines)
telar_add_test(gui-glyph-ink-probe PROBE SOURCES ${TELAR_PROCESS_SOURCE_DIR}/tools/glyph_ink_probe.cpp LIBRARIES gui-foundation-core gui-foundation-fonts
  CHECKS lint lifetime blank_lines)
telar_add_test(gui-awake-clock-test SOURCES awake_clock_test.cpp LIBRARIES gui-foundation-system gui-platform
  TEST gui-awake-clock LABELS gui.platform TIMEOUT 30)
telar_add_test(gui-wall-clock-test NO_TEST SOURCES wall_clock_test.cpp LIBRARIES gui-foundation-system gui-platform)
function(gui_add_wall_clock_test name zone offset)
  telar_add_test(${name} COMMAND "${CMAKE_COMMAND}" -E env "TZ=${zone}" $<TARGET_FILE:gui-wall-clock-test> "${offset}"
    LABELS gui.platform TIMEOUT 30)
endfunction()
gui_add_wall_clock_test(gui-wall-clock UTC0 0)
gui_add_wall_clock_test(gui-wall-clock-nepal NPT-5:45 345)
gui_add_wall_clock_test(gui-wall-clock-newfoundland NST3:30 -210)
gui_add_wall_clock_test(gui-wall-clock-line-islands LINT-14 840)
gui_add_wall_clock_test(gui-wall-clock-baker-island IDLW12 -720)
telar_add_test(gui-agent-replica-test SOURCES agent_replica_test.cpp LIBRARIES gui-foundation-model gui-application gui-test-fixtures
  TEST gui-agent-replica LABELS gui.application TIMEOUT 30)
telar_add_test(gui-tab-activity-test SOURCES tab_activity_test.cpp LIBRARIES gui-foundation-model gui-foundation-drawing gui-foundation-core gui-features-terminal-graphics gui-application gui-test-fixtures
  TEST gui-tab-activity LABELS gui.features.activity)
target_compile_options(gui-tab-activity-test PRIVATE -ffp-contract=off)
telar_add_test(gui-project-activity-test SOURCES project_activity_test.cpp LIBRARIES gui-foundation-model gui-foundation-text gui-foundation-system gui-application gui-test-fixtures
  TEST gui-project-activity LABELS gui.foundation.model)
telar_add_test(gui-activity-test SOURCES activity_test.cpp LIBRARIES gui-foundation-model gui-foundation-core gui-application gui-test-fixtures
  TEST gui-activity LABELS gui.application TIMEOUT 30)
telar_add_test(gui-machine-chrome-test SOURCES machine_chrome_test.cpp LIBRARIES gui-foundation-core gui-features-machines
  TEST gui-machine-chrome LABELS gui.features.machines)
target_compile_options(gui-machine-chrome-test PRIVATE -ffp-contract=off)
telar_add_test(gui-session-test SOURCES session_test.cpp LIBRARIES gui-foundation-keys gui-foundation-model gui-foundation-core gui-features-history gui-application gui-test-fixtures
  TEST gui-session LABELS gui.application TIMEOUT 30)
telar_add_test(gui-document-session-test SOURCES document_session_test.cpp LIBRARIES gui-application gui-test-fixtures
  TEST gui-document-session LABELS gui.application)
telar_add_test(gui-scroll-test SOURCES scroll_test.cpp LIBRARIES gui-foundation-terminal gui-features-terminal-links gui-application gui-test-fixtures
  TEST gui-scroll LABELS gui.application)
telar_add_test(gui-host-metrics-test SOURCES host_metrics_test.cpp LIBRARIES gui-foundation-core gui-application gui-test-fixtures
  TEST gui-host-metrics LABELS gui.application)
telar_add_test(gui-palette-test SOURCES palette_test.cpp LIBRARIES gui-foundation-core gui-foundation-text gui-features-palette
  TEST gui-palette LABELS gui.features.palette)
target_compile_options(gui-palette-test PRIVATE -ffp-contract=off)

telar_add_test(gui-worktree-actions-test SOURCES worktree_actions_test.cpp LIBRARIES gui-application gui-test-fixtures
  TEST gui-worktree-actions LABELS gui.application)
telar_add_test(gui-workspace-navigation-test SOURCES workspace_navigation_test.cpp LIBRARIES gui-foundation-model gui-application gui-test-fixtures
  TEST gui-workspace-navigation LABELS gui.application)

telar_add_test(gui-agent-peek-test SOURCES agent_peek_test.cpp LIBRARIES gui-foundation-core gui-features-peek gui-application gui-test-fixtures
  TEST gui-agent-peek LABELS gui.features.peek)
telar_add_test(gui-runtime-link-test SOURCES runtime_link_test.cpp LIBRARIES gui-features-machines gui-application
  TEST gui-runtime-link LABELS gui.application)
telar_add_test(gui-runtime-handshake-test SOURCES runtime_handshake_test.cpp LIBRARIES gui-features-machines gui-application
  TEST gui-runtime-handshake LABELS gui.application)

telar_add_test(gui-path-picker-session-test SOURCES path_picker_session_test.cpp LIBRARIES gui-features-paths gui-application gui-test-fixtures
  TEST gui-path-picker-session LABELS gui.features.paths)

telar_add_test(gui-path-picker-test SOURCES path_picker_test.cpp LIBRARIES gui-foundation-core gui-features-paths deps::ghostty_vt
  TEST gui-path-picker LABELS gui.features.paths)

telar_add_test(gui-suggestion-state-test SOURCES suggestion_state_test.cpp LIBRARIES gui-foundation-keys gui-foundation-model gui-foundation-forms gui-foundation-core gui-foundation-terminal gui-features-palette deps::ghostty_vt
  TEST gui-suggestion-state LABELS gui.features.palette)

telar_add_test(gui-prompt-editor-test SOURCES prompt_editor_test.cpp LIBRARIES gui-features-prompt
  TEST gui-prompt-editor LABELS gui.features.prompt)

telar_add_test(gui-prompt-session-test SOURCES prompt_session_test.cpp LIBRARIES gui-foundation-core gui-application gui-test-fixtures
  TEST gui-prompt-session LABELS gui.features.prompt)

telar_add_test(gui-suggestion-session-test SOURCES suggestion_session_test.cpp LIBRARIES gui-features-palette gui-application gui-test-fixtures
  TEST gui-suggestion-session LABELS gui.features.palette)

telar_add_test(gui-machine-profiles-test SOURCES machine_profiles_test.cpp LIBRARIES gui-features-machines
  TEST gui-machine-profiles LABELS gui.features.machines)

telar_add_test(gui-machine-opening-test SOURCES machine_opening_test.cpp LIBRARIES gui-features-machines
  TEST gui-machine-opening LABELS gui.features.machines)

telar_add_test(gui-machine-runtime-location-test SOURCES machine_runtime_location_test.cpp LIBRARIES gui-platform gui-features-machines gui-foundation-system
  TEST gui-machine-runtime-location LABELS gui.features.machines)

telar_add_test(gui-machines-test SOURCES machines_test.cpp LIBRARIES gui-features-machines
  TEST gui-features-machines LABELS gui.features.machines)
telar_add_test(gui-json-integer-test SOURCES json_integer_test.cpp LIBRARIES gui-foundation-core
  TEST gui-json-integer LABELS gui.features.machines)

telar_add_test(gui-machine-remote-test SOURCES machine_remote_test.cpp LIBRARIES gui-features-machines
  TEST gui-machine-remote LABELS gui.features.machines)

telar_add_test(gui-machine-profile-store-test SOURCES machine_profile_store_test.cpp LIBRARIES gui-features-machines
  TEST gui-machine-profile-store LABELS gui.features.machines)

telar_add_test(gui-machine-profile-file-test SOURCES machine_profile_file_test.cpp LIBRARIES gui-posix Threads::Threads gui-platform gui-features-machines gui-foundation-system
  TEST gui-machine-profile-file LABELS gui.features.machines TIMEOUT 30)

telar_add_test(gui-machine-presentation-test SOURCES machine_presentation_test.cpp LIBRARIES gui-foundation-model gui-application gui-test-fixtures
  TEST gui-machine-presentation LABELS gui.features.machines)

telar_add_test(gui-history-test SOURCES history_test.cpp LIBRARIES gui-foundation-core gui-features-history
  TEST gui-features-history LABELS gui.features.history TIMEOUT 30)
telar_add_test(gui-history-card-test SOURCES history_card_test.cpp LIBRARIES gui-foundation-forms gui-foundation-core gui-foundation-text gui-features-history deps::ghostty_vt gui-test-fixtures
  TEST gui-history-card LABELS gui.features.history TIMEOUT 30)
telar_add_test(gui-editor-test SOURCES editor_test.cpp LIBRARIES gui-foundation-forms gui-foundation-core gui-foundation-text gui-foundation-terminal deps::ghostty_vt gui-test-fixtures
  TEST gui-editor LABELS gui.foundation.text)
telar_add_test(gui-bindings-test SOURCES input_test.cpp LIBRARIES gui-foundation-actions gui-foundation-keys gui-features-history gui-features-bindings gui-features-machines
  TEST gui-bindings LABELS gui.features.bindings TIMEOUT 30)
telar_add_test(gui-key-encoder-test SOURCES key_encoder_test.cpp LIBRARIES gui-foundation-actions gui-foundation-keys gui-foundation-core
  TEST gui-key-encoder LABELS gui.foundation.keys TIMEOUT 30)
telar_add_test(gui-copy-mode-test SOURCES copy_mode_test.cpp LIBRARIES gui-foundation-terminal gui-features-terminal-copy_mode gui-test-fixtures
  TEST gui-copy-mode LABELS gui.features.terminal.copy_mode TIMEOUT 30)
telar_add_test(gui-directory-completion-test SOURCES directory_completion_test.cpp LIBRARIES gui-foundation-system
  TEST gui-directory-completion LABELS gui.foundation.system TIMEOUT 30)
telar_add_test(gui-links-test SOURCES links_test.cpp LIBRARIES gui-foundation-core gui-foundation-terminal gui-features-terminal-links gui-test-fixtures
  TEST gui-features-terminal-links LABELS gui.features.terminal.links TIMEOUT 30)
telar_add_test(gui-file-links-test SOURCES file_links_test.cpp LIBRARIES gui-features-terminal-links
  TEST gui-file-links LABELS gui.features.terminal.links TIMEOUT 30)
telar_add_test(gui-editor-session-test SOURCES editor_session_test.cpp LIBRARIES gui-foundation-model gui-features-terminal-links gui-application gui-test-fixtures
  TEST gui-editor-session LABELS gui.application TIMEOUT 30)
telar_add_test(gui-link-interaction-test SOURCES link_interaction_test.cpp LIBRARIES gui-foundation-core gui-foundation-terminal gui-features-terminal-links gui-test-fixtures
  TEST gui-link-interaction LABELS gui.features.terminal.links TIMEOUT 30)
telar_add_test(gui-child-mouse-test SOURCES child_mouse_test.cpp LIBRARIES gui-foundation-core gui-features-terminal-input
  TEST gui-child-mouse LABELS gui.features.terminal.input TIMEOUT 30)
telar_add_test(gui-cell-glyphs-test SOURCES cell_glyphs_test.cpp LIBRARIES gui-foundation-core gui-foundation-terminal gui-foundation-fonts gui-test-fixtures
  TEST gui-cell-glyphs LABELS gui.foundation.terminal)
telar_add_test(gui-workbench-layout-test SOURCES layout_test.cpp LIBRARIES gui-features-workbench gui-foundation-model gui-foundation-core
  TEST LABELS gui.features.workbench TIMEOUT 30)
telar_add_test(gui-graphics-test SOURCES graphics_test.cpp LIBRARIES gui-foundation-core gui-foundation-terminal gui-features-terminal-graphics gui-test-fixtures
  TEST gui-features-terminal-graphics LABELS gui.features.terminal.graphics TIMEOUT 30)
telar_add_test(gui-config-test SOURCES configuration_test.cpp LIBRARIES gui-foundation-actions gui-foundation-core gui-application
  TEST gui-config LABELS gui.application TIMEOUT 30)
telar_add_test(gui-component-config-test SOURCES component_configuration_test.cpp LIBRARIES gui-foundation-actions gui-foundation-core gui-features-components gui-application
  TEST gui-component-config LABELS gui.features.components TIMEOUT 30)
target_compile_definitions(gui-component-config-test PRIVATE TELAR_GUI_EXAMPLES_DIR="${TELAR_ROOT}/docs/examples")

telar_add_test(gui-pick-items-test SOURCES pick_items_test.cpp LIBRARIES gui-application gui-foundation-core gui-features-components
  TEST gui-pick-items LABELS gui.features.components TIMEOUT 30)
telar_add_test(gui-platform-test SOURCES platform_test.cpp LIBRARIES gui-foundation-system gui-posix gui-platform
  TEST gui-platform LABELS gui.platform TIMEOUT 30)

if(TELAR_GUI_NATIVE)
  telar_add_test(gui-test-font-fixture STATIC SOURCES font_fixture/font_fixture.cppm LIBRARIES gui-foundation-core gui-foundation-fonts gui-fonts-native gui-test-fixtures)
  telar_add_test(gui-font-cascade-test SOURCES font_cascade_test.cpp LIBRARIES gui-foundation-fonts gui-fonts-native deps::ghostty_vt gui-test-font-fixture
    TEST gui-font-cascade ARGS "${TELAR_ROOT}/assets" LABELS gui.foundation.fonts)
  target_compile_options(gui-font-cascade-test PRIVATE -ffp-contract=off)
  telar_add_test(gui-row-text-test SOURCES row_text_test.cpp LIBRARIES gui-foundation-fonts gui-fonts-native deps::ghostty_vt gui-test-font-fixture
    TEST gui-row-text ARGS "${TELAR_ROOT}/assets" LABELS gui.foundation.fonts)
  target_compile_options(gui-row-text-test PRIVATE -ffp-contract=off)
  telar_add_test(gui-font-coverage-probe PROBE SOURCES ${TELAR_PROCESS_SOURCE_DIR}/tools/font_coverage_probe.cpp LIBRARIES gui-foundation-core gui-foundation-fonts gui-fonts-native
    CHECKS lint lifetime blank_lines)

  set(CMAKE_AUTOMOC ON)
  set(CMAKE_AUTOUIC ON)
  telar_add_test(gui-display-probe PROBE SOURCES ${TELAR_PROCESS_SOURCE_DIR}/tools/display_probe.cpp LIBRARIES Qt6::Gui telar::build_flags
    CHECKS lint lifetime blank_lines)
  telar_add_test(gui-surface-command-test SOURCES surface_command_test.cpp LIBRARIES gui-surface-command
    TEST gui-surface-command LABELS gui.ui TIMEOUT 30)
  telar_add_test(gui-native-pointer-events-test SOURCES native_pointer_events_test.cpp ${TELAR_PROCESS_SOURCE_DIR}/ui/foundation/input/native_pointer_events.cpp LIBRARIES gui-foundation-core Qt6::Gui Qt6::GuiPrivate
    TEST gui-native-pointer-events LABELS gui.ui ENVIRONMENT QT_QPA_PLATFORM=offscreen TIMEOUT 30)
  telar_add_test(gui-background-blur-radius-test SOURCES background_blur_radius_test.cpp LIBRARIES gui-foundation-core
    TEST gui-background-blur-radius LABELS gui.platform)
  if(APPLE)
    telar_add_test(gui-native-scroll-input-test SOURCES native_scroll_input_test.mm LIBRARIES gui-platform-native Qt6::Gui
      TEST gui-native-scroll-input LABELS gui.platform ENVIRONMENT QT_QPA_PLATFORM=cocoa TIMEOUT 30)
    target_compile_options(gui-native-scroll-input-test PRIVATE -fobjc-arc)
    if(TELAR_GUI_HAS_OBJC_CLASS_STUB_CONTROL)
      target_compile_options(gui-native-scroll-input-test PRIVATE -fno-objc-msgsend-class-selector-stubs)
    endif()
    telar_add_test(gui-native-window-appearance-test SOURCES native_window_appearance_test.mm LIBRARIES gui-platform-native Qt6::Quick
      TEST gui-native-window-appearance LABELS gui.platform ENVIRONMENT QT_QPA_PLATFORM=cocoa TIMEOUT 30)
    target_compile_options(gui-native-window-appearance-test PRIVATE -fobjc-arc)
    if(TELAR_GUI_HAS_OBJC_CLASS_STUB_CONTROL)
      target_compile_options(gui-native-window-appearance-test PRIVATE -fno-objc-msgsend-class-selector-stubs)
    endif()
    telar_add_test(gui-native-window-update-test SOURCES native_window_update_test.cpp LIBRARIES gui-foundation-core gui-foundation-system gui-platform-native Qt6::Quick Qt6::GuiPrivate gui-platform gui-application
      TEST gui-native-window-update LABELS gui.platform ENVIRONMENT QT_QPA_PLATFORM=cocoa TIMEOUT 30)
    telar_add_test(gui-clipboard-image-source-test SOURCES clipboard_image_source_test.mm LIBRARIES gui-platform-native
      TEST gui-clipboard-image-source LABELS gui.platform TIMEOUT 30)
    target_compile_options(gui-clipboard-image-source-test PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
    if(TELAR_GUI_HAS_OBJC_CLASS_STUB_CONTROL)
      target_compile_options(gui-clipboard-image-source-test PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fno-objc-msgsend-class-selector-stubs>")
    endif()
    if(TELAR_SANITIZERS)
      target_compile_options(gui-clipboard-image-source-test PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fsanitize=address,undefined;-fno-omit-frame-pointer>")
    endif()
  elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    pkg_check_modules(GUI_WAYLAND_SERVER REQUIRED IMPORTED_TARGET wayland-server)
    find_package(Qt6 ${TELAR_QT_VERSION} EXACT REQUIRED COMPONENTS WaylandCompositor
      PATHS "${TELAR_GUI_QT_PREFIX}/lib/cmake/Qt6" NO_DEFAULT_PATH)
    find_package(Qt6WaylandCompositorPrivate ${TELAR_QT_VERSION} EXACT REQUIRED CONFIG
      PATHS "${TELAR_GUI_QT_PREFIX}/lib/cmake/Qt6WaylandCompositorPrivate" NO_DEFAULT_PATH)
    telar_add_test(gui-background-effect-server QT NO_TEST SOURCES ${TELAR_PROCESS_SOURCE_DIR}/tools/background_effect_server.cpp LIBRARIES gui-foundation-core Qt6::WaylandCompositorPrivate PkgConfig::GUI_WAYLAND_SERVER
      CHECKS lint lifetime blank_lines)
    qt_generate_wayland_protocol_server_sources(gui-background-effect-server FILES "${GUI_BACKGROUND_EFFECT_XML}")
    set_target_properties(gui-background-effect-server PROPERTIES QT_QML_MODULE_NO_IMPORT_SCAN TRUE)
    telar_add_test(gui-background-effect-probe QT NO_TEST SOURCES ${TELAR_PROCESS_SOURCE_DIR}/tools/background_effect_probe.cpp LIBRARIES gui-platform-native Qt6::Gui
      CHECKS lint lifetime blank_lines)
    set_target_properties(gui-background-effect-probe PROPERTIES QT_QML_MODULE_NO_IMPORT_SCAN TRUE)
    telar_add_test(gui-clipboard-wayland-lifecycle-server NO_TEST SOURCES ${TELAR_PROCESS_SOURCE_DIR}/tools/clipboard_wayland_lifecycle_server.c LIBRARIES PkgConfig::GUI_WAYLAND_SERVER
      CHECKS lint lifetime blank_lines)
    telar_add_test(gui-clipboard-wayland-lifecycle-probe NO_TEST SOURCES ${TELAR_PROCESS_SOURCE_DIR}/tools/clipboard_wayland_lifecycle_probe.cpp LIBRARIES gui-platform-native Qt6::Core gui-platform
      CHECKS lint lifetime blank_lines)
    telar_add_test(gui-clipboard-wayland-provider QT NO_TEST SOURCES ${TELAR_PROCESS_SOURCE_DIR}/tools/clipboard_wayland_provider.cpp LIBRARIES Qt6::Quick
      CHECKS lint lifetime blank_lines)
    telar_add_test(gui-clipboard-wayland-probe QT NO_TEST SOURCES ${TELAR_PROCESS_SOURCE_DIR}/tools/clipboard_wayland_probe.cpp LIBRARIES gui-clipboard-images Qt6::Quick gui-features-machines
      CHECKS lint lifetime blank_lines)
    telar_add_test(gui-clipboard-wayland-owned-probe QT NO_TEST SOURCES ${TELAR_PROCESS_SOURCE_DIR}/tools/clipboard_wayland_owned_probe.cpp LIBRARIES gui-clipboard-images Qt6::Quick PkgConfig::GUI_WAYLAND_CLIENT gui-features-machines
      CHECKS lint lifetime blank_lines)
    target_include_directories(gui-clipboard-wayland-probe PRIVATE "${TELAR_PROCESS_SOURCE_DIR}")
    set_target_properties(gui-clipboard-wayland-provider gui-clipboard-wayland-probe PROPERTIES QT_QML_MODULE_NO_IMPORT_SCAN TRUE)
  endif()
  telar_add_test(gui-attachment-preview-test SOURCES attachment_preview_test.cpp ${TELAR_PROCESS_SOURCE_DIR}/ui/app/panes/attachments/attachment_preview.cpp LIBRARIES gui-features-terminal-attachments gui-features-terminal-graphics gui-application Qt6::Gui
    TEST gui-attachment-preview LABELS gui.ui TIMEOUT 30)
  target_include_directories(gui-attachment-preview-test PRIVATE "${TELAR_PROCESS_SOURCE_DIR}")

  if(APPLE)
    if(NOT DEFINED CMAKE_OBJC_COMPILER AND "$ENV{OBJC}" STREQUAL "" AND CMAKE_CXX_COMPILER_ID MATCHES "Clang")
      set(CMAKE_OBJC_COMPILER "${CMAKE_CXX_COMPILER}")
    endif()

    enable_language(OBJC)
    telar_add_test(gui-optical-text-test SOURCES optical_text_test.cpp LIBRARIES gui-quick
      TEST gui-optical-text LABELS gui.ui ENVIRONMENT QT_QPA_PLATFORM=offscreen TIMEOUT 30)
    target_include_directories(gui-optical-text-test PRIVATE "${TELAR_PROCESS_SOURCE_DIR}/platform/macos")
  endif()
  telar_add_test(gui-qt-dependency COMMAND Python3::Interpreter "${TELAR_PROCESS_SOURCE_DIR}/tools/test_qt_dependency.py"
    LABELS gui.platform ENVIRONMENT "TELAR_GUI_QT_CACHE=${CMAKE_BINARY_DIR}/CMakeCache.txt" TIMEOUT 30)
  find_package(Qt6 ${TELAR_QT_VERSION} EXACT REQUIRED COMPONENTS Test
    PATHS "${TELAR_GUI_QT_PREFIX}/lib/cmake/Qt6" NO_DEFAULT_PATH)
  # Package inspection hashes contents with OpenSSL; the GUI itself does not link it.
  include("${TELAR_ROOT}/cmake/openssl.cmake")
  telar_add_test(gui-plugin-packages-test SOURCES plugin_packages_test.cpp LIBRARIES gui-posix Qt6::Core OpenSSL::Crypto gui-test-fixtures
    TEST gui-plugin-packages LABELS gui.ui TIMEOUT 30)
  telar_add_test(gui-ssh-runtime-fixture NO_TEST SOURCES ssh_runtime_fixture.cpp LIBRARIES gui-foundation-core)
  telar_add_test(gui-remote-connection-test QT SOURCES remote_connection_test.cpp ${TELAR_PROCESS_SOURCE_DIR}/ui/foundation/machines/runtime_connection.cpp ${TELAR_PROCESS_SOURCE_DIR}/ui/foundation/machines/runtime_connection.hpp LIBRARIES gui-foundation-system gui-posix Qt6::Concurrent Qt6::Network Qt6::Test gui-platform gui-features-machines gui-application gui-application
    TEST gui-remote-connection LABELS gui.ui TIMEOUT 30)
  target_include_directories(gui-remote-connection-test PRIVATE "${TELAR_PROCESS_SOURCE_DIR}")
  add_dependencies(gui-remote-connection-test gui-ssh-runtime-fixture)
  telar_add_test(gui-runtime-compatibility-probe QT PROBE SOURCES ${TELAR_PROCESS_SOURCE_DIR}/tools/runtime_compatibility_probe.cpp ${TELAR_PROCESS_SOURCE_DIR}/ui/foundation/machines/runtime_connection.cpp ${TELAR_PROCESS_SOURCE_DIR}/ui/foundation/machines/runtime_connection.hpp LIBRARIES gui-foundation-system gui-posix Qt6::Concurrent Qt6::Network gui-platform gui-features-machines gui-application gui-application
    CHECKS lint lifetime blank_lines)
  target_include_directories(gui-runtime-compatibility-probe PRIVATE "${TELAR_PROCESS_SOURCE_DIR}")
  telar_add_test(gui-local-runtime-endpoint-test QT SOURCES local_runtime_endpoint_test.cpp LIBRARIES gui-foundation-system gui-posix Qt6::Network Qt6::Test gui-platform
    TEST gui-local-runtime-endpoint LABELS gui.ui TIMEOUT 30)
  target_include_directories(gui-local-runtime-endpoint-test PRIVATE "${TELAR_PROCESS_SOURCE_DIR}")
  telar_add_test(gui-remote-bridge-test QT SOURCES remote_bridge_test.cpp LIBRARIES gui-foundation-system gui-posix Qt6::Concurrent Qt6::Network Qt6::Test gui-platform gui-features-machines gui-application
    TEST gui-remote-bridge LABELS gui.ui TIMEOUT 30)
  target_include_directories(gui-remote-bridge-test PRIVATE "${TELAR_PROCESS_SOURCE_DIR}")
  telar_add_test(gui-machine-profile-window-test QT SOURCES machine_profile_window_test.cpp LIBRARIES gui-quick gui-quickplugin Qt6::Test
    TEST gui-machine-profile-window LABELS gui.ui ENVIRONMENT QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen TIMEOUT 30)
  add_dependencies(gui-machine-profile-window-test gui-ssh-runtime-fixture)
  telar_add_test(gui-machine-window-test QT SOURCES machine_window_test.cpp LIBRARIES gui-quick gui-quickplugin Qt6::Test gui-test-fixtures
    TEST gui-machine-window LABELS gui.ui ENVIRONMENT QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen TIMEOUT 30)
  if(APPLE)
    target_sources(gui-machine-window-test PRIVATE platform/macos/private_clipboard.mm)
    target_include_directories(gui-machine-window-test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    target_compile_options(gui-machine-window-test PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
    if(TELAR_GUI_HAS_OBJC_CLASS_STUB_CONTROL)
      target_compile_options(gui-machine-window-test PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fno-objc-msgsend-class-selector-stubs>")
    endif()
    if(TELAR_SANITIZERS)
      target_compile_options(gui-machine-window-test PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fsanitize=address,undefined;-fno-omit-frame-pointer>")
    endif()
  endif()

  telar_add_test(gui-prompt-window-test QT SOURCES prompt_window_test.cpp LIBRARIES gui-quick gui-quickplugin Qt6::Test gui-test-fixtures
    TEST gui-prompt-window LABELS gui.ui ENVIRONMENT QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen TIMEOUT 30)
  target_include_directories(gui-prompt-window-test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
  telar_add_test(gui-machine-profiles-source-test QT SOURCES machine_profiles_source_test.cpp LIBRARIES gui-foundation-system gui-machine-profiles Qt6::Test gui-platform gui-features-machines
    TEST gui-machine-profiles-source LABELS gui.ui TIMEOUT 30)
  telar_add_test(gui-window-frame-pacer-test QT SOURCES window_frame_pacer_test.cpp LIBRARIES gui-foundation-core gui-foundation-system gui-platform gui-application Qt6::Quick Qt6::Test
    TEST gui-window-frame-pacer LABELS gui.ui ENVIRONMENT QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen TIMEOUT 30)
  if(APPLE)
    telar_add_test(gui-test-window-activation STATIC SOURCES platform/macos/window_activation.mm platform/window_hiding.cpp
      LIBRARIES Qt6::Gui PRIVATE Qt6::GuiPrivate "-framework AppKit" telar::build_flags)
    if(TELAR_GUI_HAS_OBJC_CLASS_STUB_CONTROL)
      target_compile_options(gui-test-window-activation PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fno-objc-msgsend-class-selector-stubs>")
    endif()
  else()
    telar_add_test(gui-test-window-activation STATIC SOURCES platform/window_activation.cpp platform/window_hiding.cpp
      LIBRARIES Qt6::Gui PRIVATE Qt6::GuiPrivate telar::build_flags)
  endif()

  telar_add_test(gui-chrome-text-test QT SOURCES chrome_text_test.cpp LIBRARIES gui-quick gui-quickplugin Qt6::Test gui-test-window-activation
    TEST gui-chrome-text LABELS gui.ui ENVIRONMENT QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen TIMEOUT 30)
  telar_add_test(gui-text-scene-probe QT PROBE SOURCES ${TELAR_PROCESS_SOURCE_DIR}/tools/text_scene_probe.cpp LIBRARIES gui-quick gui-quickplugin
    CHECKS lint lifetime blank_lines)
  telar_add_test(gui-terminal-scene-probe QT PROBE SOURCES ${TELAR_PROCESS_SOURCE_DIR}/tools/terminal_scene_probe.cpp LIBRARIES gui-quick gui-quickplugin
    CHECKS lint lifetime blank_lines)
  telar_add_test(gui-chrome-icon-test QT SOURCES chrome_icon_test.cpp LIBRARIES gui-quick gui-quickplugin Qt6::Test gui-test-window-activation
    TEST gui-chrome-icon LABELS gui.ui ENVIRONMENT QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen TIMEOUT 30)
  telar_add_test(gui-status-bar-test QT SOURCES status_bar_test.cpp LIBRARIES gui-quick gui-quickplugin Qt6::Test gui-test-fixtures
    TEST gui-status-bar LABELS gui.ui ENVIRONMENT QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen TIMEOUT 30)
  telar_add_test(gui-rounded-rectangle-test QT SOURCES rounded_rectangle_test.cpp LIBRARIES gui-quick gui-quickplugin Qt6::Test
    TEST gui-rounded-rectangle LABELS gui.ui ENVIRONMENT QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen TIMEOUT 30)
  qt_add_resources(gui-rounded-rectangle-test gui-shape-fixtures
    PREFIX "/telar/test-shapes"
    BASE "${CMAKE_CURRENT_SOURCE_DIR}/fixtures/shapes"
    FILES fixtures/shapes/cases.json fixtures/shapes/rounded-rectangles.png)
  telar_add_test(gui-mode-bar-test QT SOURCES mode_bar_test.cpp LIBRARIES gui-quick gui-quickplugin Qt6::Test
    TEST gui-mode-bar LABELS gui.ui ENVIRONMENT QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen TIMEOUT 30)
  qt_add_resources(gui-chrome-icon-test gui-icon-fixtures
    PREFIX "/telar/test-icons"
    BASE "${CMAKE_CURRENT_SOURCE_DIR}/fixtures/icons"
    FILES fixtures/icons/folder-small.png fixtures/icons/unknown-status.png)
  telar_add_test(gui-tab-activity-scene-test QT SOURCES tab_activity_scene_test.cpp LIBRARIES gui-quick gui-quickplugin Qt6::Test
    TEST gui-tab-activity-scene LABELS gui.ui ENVIRONMENT QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen TIMEOUT 30)
  qt_add_resources(gui-tab-activity-scene-test gui-progress-fixtures
    PREFIX "/telar/test-tab-activity"
    BASE "${CMAKE_CURRENT_SOURCE_DIR}/fixtures/tab-activity"
    FILES fixtures/tab-activity/cases.json fixtures/tab-activity/atlas.png)
  target_compile_options(gui-tab-activity-scene-test PRIVATE -ffp-contract=off)
  telar_add_test(gui-graphics-retention-scene-test QT SOURCES graphics_retention_scene_test.cpp LIBRARIES gui-quick gui-quickplugin Qt6::Test
    TEST gui-graphics-retention-scene LABELS gui.ui ENVIRONMENT QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen TIMEOUT 30)
  telar_add_test(gui-graphics-recovery-scene-test QT SOURCES graphics_recovery_scene_test.cpp controlled_awake_clock.cpp LIBRARIES gui-quick gui-quickplugin Qt6::Test
    TEST gui-graphics-recovery-scene LABELS gui.ui ENVIRONMENT QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen TIMEOUT 30)
  telar_add_test(gui-pane-attention-test QT SOURCES pane_attention_test.cpp controlled_awake_clock.cpp LIBRARIES gui-quick gui-quickplugin Qt6::Test
    TEST gui-pane-attention LABELS gui.ui ENVIRONMENT QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen TIMEOUT 30)
  qt_add_resources(gui-pane-attention-test gui-pane-attention-fixtures
    PREFIX "/telar/test-pane-attention"
    BASE "${CMAKE_CURRENT_SOURCE_DIR}/fixtures/pane-attention"
    FILES fixtures/pane-attention/cases.json fixtures/pane-attention/alpha-0.png fixtures/pane-attention/alpha-90000000.png fixtures/pane-attention/alpha-180000000.png fixtures/pane-attention/alpha-360000000.png)
  target_compile_options(gui-pane-attention-test PRIVATE -ffp-contract=off)
  telar_add_test(gui-notification-overlay-test QT SOURCES notification_overlay_test.cpp LIBRARIES gui-quick gui-quickplugin Qt6::Test gui-test-window-activation
    TEST gui-notification-overlay LABELS gui.ui ENVIRONMENT QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen TIMEOUT 30)
  telar_add_test(gui-chrome-test QT SOURCES chrome_test.cpp LIBRARIES gui-quick gui-quickplugin Qt6::Test
    TEST gui-chrome LABELS gui.ui ENVIRONMENT QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen TIMEOUT 30)
  telar_add_test(gui-pane-header-test QT SOURCES pane_header_test.cpp LIBRARIES gui-quick gui-quickplugin Qt6::Test
    TEST gui-pane-header LABELS gui.ui ENVIRONMENT QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen TIMEOUT 30)
  telar_add_test(gui-agent-timeline-test QT SOURCES agent_timeline_test.cpp LIBRARIES gui-quick gui-quickplugin Qt6::Test gui-test-fixtures
    TEST gui-agent-timeline LABELS gui.ui ENVIRONMENT QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen TIMEOUT 30)
  telar_add_test(gui-agent-card-test QT SOURCES agent_card_test.cpp LIBRARIES gui-quick gui-quickplugin Qt6::Test
    TEST gui-agent-card LABELS gui.ui ENVIRONMENT QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen TIMEOUT 30)
  telar_add_test(gui-task-card-test QT SOURCES task_card_test.cpp LIBRARIES gui-quick gui-quickplugin Qt6::Test gui-test-fixtures
    TEST gui-task-card LABELS gui.ui ENVIRONMENT QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen TIMEOUT 30)
  telar_add_test(gui-window-test QT SOURCES window_test.cpp LIBRARIES gui-quick gui-quickplugin Qt6::Test
    TEST gui-window LABELS gui.ui ENVIRONMENT QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen TIMEOUT 30)
  telar_add_test(gui-font-resolver-test QT SOURCES font_resolver_test.cpp LIBRARIES gui-quick gui-quickplugin Qt6::Test
    TEST gui-font-resolver LABELS gui.ui ENVIRONMENT QT_QPA_PLATFORM=offscreen TIMEOUT 30)
  qt_add_resources(gui-font-resolver-test gui-font-fixtures
    PREFIX "/telar/test-fonts"
    BASE "${CMAKE_CURRENT_SOURCE_DIR}/fixtures"
    FILES fixtures/metrics-variable.ttf fixtures/metrics-collection.ttc fixtures/metrics-wide-glyph.ttf)
  telar_add_test(gui-configuration-source-test QT SOURCES configuration_source_test.cpp LIBRARIES gui-quick gui-quickplugin Qt6::Test gui-test-fixtures
    TEST gui-configuration-source LABELS gui.ui ENVIRONMENT QT_QPA_PLATFORM=offscreen TIMEOUT 30)
  telar_add_test(gui-configuration-reload-probe QT PROBE SOURCES ${TELAR_PROCESS_SOURCE_DIR}/tools/configuration_reload_probe.cpp LIBRARIES gui-quick gui-quickplugin
    CHECKS lint lifetime blank_lines)
  telar_add_test(gui-separators-probe QT PROBE SOURCES ${TELAR_PROCESS_SOURCE_DIR}/tools/separators_probe.cpp LIBRARIES gui-quick gui-quickplugin gui-test-fixtures
    CHECKS lint lifetime blank_lines)
  telar_add_test(gui-key-adapter-test SOURCES key_adapter_test.cpp LIBRARIES gui-foundation-actions gui-foundation-keys gui-foundation-core gui-foundation-system gui-keyboard gui-platform
    TEST gui-key-adapter LABELS gui.ui TIMEOUT 30)
  telar_add_test(gui-link-opener-test QT SOURCES link_opener_test.cpp LIBRARIES gui-foundation-model gui-foundation-agents gui-foundation-core gui-foundation-system gui-foundation-text gui-features-history gui-features-terminal-links gui-platform gui-application deps::ghostty_vt Qt6::Gui Qt6::Test
    TEST gui-link-opener LABELS gui.ui TIMEOUT 30)
  target_include_directories(gui-link-opener-test PRIVATE "${TELAR_PROCESS_SOURCE_DIR}")
  telar_add_test(gui-plugin-worker-test QT SOURCES plugin_worker_test.cpp LIBRARIES gui-foundation-actions gui-posix Qt6::Concurrent Qt6::Test gui-features-plugins gui-application
    TEST gui-plugin-worker LABELS gui.ui TIMEOUT 30)
  target_include_directories(gui-plugin-worker-test PRIVATE "${TELAR_PROCESS_SOURCE_DIR}")
  telar_add_test(gui-pick-controller-test SOURCES pick_controller_test.cpp LIBRARIES gui-features-machines gui-features-components gui-surface-command gui-application
    TEST gui-pick-controller LABELS gui.ui TIMEOUT 30)
  telar_add_test(gui-host-effects-test QT SOURCES host_effects_test.cpp LIBRARIES gui-foundation-model gui-foundation-agents gui-foundation-core gui-foundation-text gui-features-history gui-platform gui-application deps::ghostty_vt Qt6::Core Qt6::Gui Qt6::Test gui-test-fixtures
    TEST gui-host-effects LABELS gui.ui TIMEOUT 30)
  telar_add_test(gui-scene-test QT SOURCES scene_test.cpp LIBRARIES gui-quick gui-quickplugin Qt6::Test
    TEST gui-scene LABELS gui.ui ENVIRONMENT QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen TIMEOUT 60)
  telar_add_test(gui-form-field-test QT SOURCES form_field_test.cpp LIBRARIES gui-quick gui-quickplugin Qt6::Test gui-test-window-activation
    TEST gui-form-field LABELS gui.ui ENVIRONMENT QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen TIMEOUT 30)
  telar_add_test(gui-list-model-test SOURCES list_model_test.cpp LIBRARIES Qt6::Gui Qt6::Test telar::build_flags
    TEST gui-list-model LABELS gui.ui TIMEOUT 30)
  target_include_directories(gui-list-model-test PRIVATE "${TELAR_PROCESS_SOURCE_DIR}")
  telar_add_test(gui-history-controls-test QT SOURCES history_controls_test.cpp LIBRARIES gui-quick gui-quickplugin Qt6::Test gui-test-window-activation
    TEST gui-history-controls LABELS gui.ui ENVIRONMENT QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen TIMEOUT 30)
  telar_add_test(gui-modal-reveal-test QT SOURCES modal_reveal_test.cpp LIBRARIES gui-quick gui-quickplugin Qt6::Test gui-test-window-activation
    TEST gui-modal-reveal LABELS gui.ui ENVIRONMENT QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen TIMEOUT 30)
  telar_add_test(gui-pane-motion-test QT SOURCES pane_motion_test.cpp LIBRARIES gui-quick gui-quickplugin Qt6::Test gui-test-window-activation
    TEST gui-pane-motion LABELS gui.ui ENVIRONMENT QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen TIMEOUT 30)
  target_compile_options(gui-pane-motion-test PRIVATE -ffp-contract=off)
  telar_add_test(gui-animation-cadence-tools COMMAND Python3::Interpreter "${TELAR_PROCESS_SOURCE_DIR}/tools/test_animation_cadence.py"
    LABELS gui.ui TIMEOUT 10)
  telar_add_test(gui-startup-tools COMMAND Python3::Interpreter "${TELAR_PROCESS_SOURCE_DIR}/tools/test_measure_startup.py"
    LABELS gui.ui TIMEOUT 30)
  if(APPLE)
    telar_add_test(gui-animation-probe QT PROBE SOURCES ${TELAR_PROCESS_SOURCE_DIR}/tools/animation_probe.cpp ${TELAR_PROCESS_SOURCE_DIR}/tools/animation_presentation.mm LIBRARIES gui-quick gui-quickplugin gui-test-window-activation "-framework Metal" "-framework QuartzCore"
      CHECKS lint lifetime blank_lines)
    target_include_directories(gui-animation-probe PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    target_compile_options(gui-animation-probe PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
    if(TELAR_GUI_HAS_OBJC_CLASS_STUB_CONTROL)
      target_compile_options(gui-animation-probe PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fno-objc-msgsend-class-selector-stubs>")
    endif()
  endif()
  telar_add_test(gui-quick-test QT NO_TEST SOURCES quick_test.cpp agent_report_fixture.cpp LIBRARIES gui-quick gui-quickplugin Qt6::Test gui-test-window-activation gui-test-fixtures)
  telar_add_test(gui-suggestion-controls-test QT NO_TEST SOURCES suggestion_controls_test.cpp LIBRARIES gui-quick gui-quickplugin Qt6::Test gui-test-window-activation)
  target_compile_definitions(gui-suggestion-controls-test PRIVATE
    TELAR_GUI_TEST_PYTHON="${Python3_EXECUTABLE}"
    TELAR_GUI_SUGGESTION_FIXTURE="${CMAKE_CURRENT_SOURCE_DIR}/suggestion_engine_fixture.py")
  set(TELAR_GUI_TEST_RUNTIME "" CACHE FILEPATH "Runtime executable for native GUI integration tests")
  if(TELAR_GUI_TEST_RUNTIME)
    get_filename_component(gui_test_runtime_directory "${TELAR_GUI_TEST_RUNTIME}" DIRECTORY)
    telar_add_test(gui-quick COMMAND gui-quick-test
      LABELS gui.ui ENVIRONMENT "TELAR_GUI_TEST_RUNTIME=${TELAR_GUI_TEST_RUNTIME}" "PATH=${gui_test_runtime_directory}:$ENV{PATH}" QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen TIMEOUT 90)
    telar_add_test(gui-suggestion-controls COMMAND gui-suggestion-controls-test
      LABELS gui.ui ENVIRONMENT "TELAR_GUI_TEST_RUNTIME=${TELAR_GUI_TEST_RUNTIME}" QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen TIMEOUT 90)
  endif()
endif()

telar_gui_scan_moc_imports()
