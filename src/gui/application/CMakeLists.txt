telar_add_domain(gui application
  SOURCES
    application-activity.cpp
    application-configuration.cpp
    application-configuration_readers.cpp
    application-history.cpp
    application-host_effects.cpp
    application-notifications.cpp
    application-palette.cpp
    application-paths.cpp
    application-peek.cpp
    application-prompt.cpp
    application-session-agents.cpp
    application-session-blocks.cpp
    application-session-commands.cpp
    application-session-graphics.cpp
    application-session-history.cpp
    application-session-layout.cpp
    application-session-prompt.cpp
    application-session-terminal.cpp
    application-session.cpp
    application-sidebar.cpp
    application-status_bar.cpp
    application-terminal_copy_mode.cpp
    application-terminal_graphics.cpp
    application-terminal_input.cpp
    application-terminal_links.cpp
    application-transport.cpp
    application-window.cpp
    application-workbench.cpp
    application-workspace_replica.cpp
  DEPS foundation/core foundation/system foundation/text foundation/terminal foundation/actions
       foundation/keys foundation/model foundation/agents features/peek features/palette features/paths features/history
       features/prompt features/terminal/input features/terminal/links features/terminal/copy_mode
       features/terminal/graphics features/terminal/attachments features/window features/status_bar features/notifications features/machines features/activity
       features/workbench features/bindings features/components features/configuration features/plugins)

if(BUILD_TESTING)
  # The fixtures shared with the UI's tests are in src/gui/tests; shared_image maps its
  # images through gui-posix.
  telar_add_domain_tests(application LINK gui-test-fixtures gui-posix TIMEOUT 30)
  target_compile_definitions(gui-application-tests PRIVATE TELAR_GUI_EXAMPLES_DIR="${TELAR_ROOT}/docs/examples")
endif()
