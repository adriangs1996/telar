cmake_minimum_required(VERSION 4.4.5)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_config LANGUAGES CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/TelarTargets.cmake")

foreach(dependency IN ITEMS ghostty lua plugins)
  if(NOT TARGET telar-${dependency})
    add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../${dependency}" "${CMAKE_BINARY_DIR}/telar-${dependency}")
  endif()
endforeach()

telar_add_library(telar-config
  SOURCES client/client.cpp core/core.cpp gui/gui.cpp runtime/runtime.cpp runtime/runtime_reader.cpp snapshot/snapshot.cpp
  INCLUDES "${CMAKE_CURRENT_SOURCE_DIR}/include"
  DEPS telar::ghostty telar::lua telar::plugins)

telar_editor_flags(telar-config GHOSTTY)
