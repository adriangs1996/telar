cmake_minimum_required(VERSION 3.24)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_config LANGUAGES CXX)

foreach(dependency IN ITEMS telar-lua telar-plugins)
  if(NOT TARGET ${dependency})
    add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../${dependency}" "${CMAKE_BINARY_DIR}/${dependency}")
  endif()
endforeach()

add_library(telar-config INTERFACE)
add_library(telar::config ALIAS telar-config)
target_include_directories(telar-config INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(telar-config INTERFACE telar::lua telar::plugins)

telar_editor_flags(telar-config GHOSTTY)
