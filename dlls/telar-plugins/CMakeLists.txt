cmake_minimum_required(VERSION 3.24)
project(telar_plugins LANGUAGES CXX)

if(NOT TARGET telar-platform)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../telar-platform" "${CMAKE_BINARY_DIR}/telar-platform")
endif()

add_library(telar-plugins INTERFACE)
add_library(telar::plugins ALIAS telar-plugins)
target_include_directories(telar-plugins INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(telar-plugins INTERFACE telar::platform)
