telar_add_domain(gui application
  SOURCES
    application-configuration.cpp
    application-history.cpp
    application-host_effects.cpp
    application-palette.cpp
    application-paths.cpp
    application-peek.cpp
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
    application-sound_playback.cpp
    application-terminal_copy_mode.cpp
    application-terminal_graphics.cpp
    application-terminal_input.cpp
    application-terminal_links.cpp
    application-workspace_replica.cpp
  DEPS foundation/core foundation/system foundation/text foundation/terminal foundation/actions
       foundation/keys foundation/model foundation/agents features/peek features/palette features/paths features/history
       features/terminal/input features/terminal/links features/terminal/copy_mode
       features/terminal/graphics core layout
       text prompt presentation components config)
