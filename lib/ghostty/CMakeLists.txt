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

set(GHOSTTY_VT_ROOT "" CACHE PATH "Installed libghostty-vt prefix")
find_path(GHOSTTY_VT_INCLUDE_DIR ghostty/vt/unicode.h HINTS "${GHOSTTY_VT_ROOT}/include" REQUIRED)
target_include_directories(telar-ghostty PUBLIC "${GHOSTTY_VT_INCLUDE_DIR}")
telar_editor_flags(telar-ghostty GHOSTTY)
