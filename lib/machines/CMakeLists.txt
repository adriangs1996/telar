cmake_minimum_required(VERSION 4.4.5)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_machines LANGUAGES CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/cpp_modules.cmake")

if(NOT TARGET telar-client)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../client" "${CMAKE_BINARY_DIR}/telar-client")
endif()

add_library(telar-machines STATIC)
add_library(telar::machines ALIAS telar-machines)
telar_modules(telar-machines)
target_include_directories(telar-machines PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(telar-machines PUBLIC telar::client)

telar_editor_flags(telar-machines)
