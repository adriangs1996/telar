telar_add_domain(gui application
  SOURCES
    application-configuration.cpp
    application-host_effects.cpp
    application-peek.cpp
    application-session-agents.cpp
    application-session-blocks.cpp
    application-session-commands.cpp
    application-session-copy_mode.cpp
    application-session-graphics.cpp
    application-session-history.cpp
    application-session-layout.cpp
    application-session-prompt.cpp
    application-session-terminal.cpp
    application-session.cpp
    application-sidebar.cpp
    application-sound_playback.cpp
    application-workspace_replica.cpp
  DEPS foundation/core foundation/system foundation/text foundation/terminal foundation/actions
       foundation/keys foundation/model foundation/agents features/peek core history layout suggestions
       text prompt links input paths presentation graphics components config)
