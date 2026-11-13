cmake_minimum_required(VERSION 4.4.5)
include("${CMAKE_CURRENT_LIST_DIR}/../../../cmake/telar_editor.cmake")
project(telar_git_checkout LANGUAGES CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../../cmake/cpp_modules.cmake")

if(NOT TARGET telar-platform)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../../platform" "${CMAKE_BINARY_DIR}/telar-platform")
endif()

# Its own target, without zlib, so the CLI links it and not the native reader.
add_library(telar-git-checkout STATIC)
add_library(telar::git-checkout ALIAS telar-git-checkout)
telar_modules(telar-git-checkout)
target_link_libraries(telar-git-checkout PUBLIC telar::platform)
target_compile_options(telar-git-checkout PRIVATE -Wall -Wextra -Wpedantic)

telar_editor_flags(telar-git-checkout)
