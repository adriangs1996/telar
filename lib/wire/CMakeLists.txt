cmake_minimum_required(VERSION 4.4.5)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_wire LANGUAGES CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/cpp_modules.cmake")

if(NOT TARGET telar-base)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../base" "${CMAKE_BINARY_DIR}/telar-base")
endif()
if(NOT TARGET telar-vocabulary)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../vocabulary" "${CMAKE_BINARY_DIR}/telar-vocabulary")
endif()

add_library(
  telar-wire STATIC
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
)
add_library(telar::wire ALIAS telar-wire)
telar_modules(telar-wire)
target_link_libraries(telar-wire PUBLIC telar::base telar::vocabulary)
# The vocabulary's textual headers still live with the client's, because Qt adapters and
# other textual headers include them by that path.
target_include_directories(telar-wire PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/../client/include")

telar_editor_flags(telar-wire)
