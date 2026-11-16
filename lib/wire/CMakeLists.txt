cmake_minimum_required(VERSION 4.4.5)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_wire LANGUAGES CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/TelarTargets.cmake")

if(NOT TARGET telar-base)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../base" "${CMAKE_BINARY_DIR}/telar-base")
endif()
if(NOT TARGET telar-vocabulary)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../vocabulary" "${CMAKE_BINARY_DIR}/telar-vocabulary")
endif()

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
  # The vocabulary's textual headers still live with the client's, because Qt adapters and
  # other textual headers include them by that path.
  INCLUDES "${CMAKE_CURRENT_SOURCE_DIR}/../client/include"
  DEPS telar::base telar::vocabulary)

telar_editor_flags(telar-wire)
