telar_add_library(telar-wire
  SOURCES
    agents/agents.cpp
    clients/clients.cpp
    clipboard/clipboard.cpp
    content/content.cpp
    editor/editor.cpp
    execution/execution.cpp
    graphics/graphics.cpp
    layout/layout.cpp
    pane_io/pane_io.cpp
    vocabulary/vocabulary.cpp
    worktrees/worktrees.cpp
  # The textual headers of the codecs, serializers and protocol messages its modules own,
  # which Qt adapters, tests and global module fragments include as telar_wire/....
  INCLUDES "${CMAKE_CURRENT_SOURCE_DIR}/include"
  DEPS telar::base telar::vocabulary)
