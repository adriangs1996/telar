telar_add_domain(gui application
  SOURCES
    host_effects/host_effects.cpp
    session/agents.cpp
    session/blocks.cpp
    session/commands.cpp
    session/copy_mode.cpp
    session/graphics.cpp
    session/history.cpp
    session/layout.cpp
    session/prompt.cpp
    session/session.cpp
    session/terminal.cpp
    sound_playback/sound_playback.cpp
    workspace_replica/workspace_replica.cpp
  DEPS foundation/core foundation/system foundation/text foundation/terminal foundation/actions
       foundation/keys foundation/model foundation/agents core history layout suggestions text
       peek prompt links input paths presentation graphics)
