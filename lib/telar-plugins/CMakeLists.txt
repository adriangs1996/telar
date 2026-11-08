cmake_minimum_required(VERSION 4.4.5)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_plugins LANGUAGES CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/cpp_modules.cmake")

if(NOT TARGET telar-platform)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../telar-platform" "${CMAKE_BINARY_DIR}/telar-platform")
endif()

add_library(telar-plugins STATIC)
add_library(telar::plugins ALIAS telar-plugins)
telar_modules(telar-plugins)
target_include_directories(telar-plugins PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(telar-plugins PUBLIC telar::platform)

telar_editor_flags(telar-plugins)
