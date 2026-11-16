cmake_minimum_required(VERSION 4.4.5)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_ghostty LANGUAGES CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/cpp_modules.cmake")

# Only libghostty-vt's headers and calls into their static inline helpers: each process that
# calls into the library links it itself.
add_library(telar-ghostty STATIC wuffs/wuffs.cpp)
add_library(telar::ghostty ALIAS telar-ghostty)
telar_modules(telar-ghostty)
target_include_directories(telar-ghostty PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")

# The headers as ordinary include directories, not system ones: the projects that link the
# library get them from deps::ghostty_vt as system headers.
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/deps/ghostty.cmake")
target_include_directories(telar-ghostty PUBLIC "$<TARGET_PROPERTY:deps::ghostty_vt,INTERFACE_INCLUDE_DIRECTORIES>")
telar_editor_flags(telar-ghostty GHOSTTY)
