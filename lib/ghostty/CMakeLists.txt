cmake_minimum_required(VERSION 4.4.5)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_ghostty LANGUAGES CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/cpp_modules.cmake")

# Only libghostty-vt's headers: each process that calls into it links the library itself.
add_library(telar-ghostty STATIC)
add_library(telar::ghostty ALIAS telar-ghostty)
telar_modules(telar-ghostty)

set(GHOSTTY_VT_ROOT "" CACHE PATH "Installed libghostty-vt prefix")
find_path(GHOSTTY_VT_INCLUDE_DIR ghostty/vt/unicode.h HINTS "${GHOSTTY_VT_ROOT}/include" REQUIRED)
target_include_directories(telar-ghostty PUBLIC "${GHOSTTY_VT_INCLUDE_DIR}")
telar_editor_flags(telar-ghostty GHOSTTY)
