cmake_minimum_required(VERSION 4.4.5)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_ghostty LANGUAGES CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/TelarTargets.cmake")

# Only libghostty-vt's headers and calls into their static inline helpers: each process that
# calls into the library links it itself.
# libghostty-vt's headers as ordinary include directories, not system ones: the projects that
# link the library get them from deps::ghostty_vt as system headers.
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/deps/ghostty.cmake")
telar_add_library(telar-ghostty
  SOURCES wuffs/wuffs.cpp
  INCLUDES "${CMAKE_CURRENT_SOURCE_DIR}/include" "$<TARGET_PROPERTY:deps::ghostty_vt,INTERFACE_INCLUDE_DIRECTORIES>")
telar_editor_flags(telar-ghostty GHOSTTY)
