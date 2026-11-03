cmake_minimum_required(VERSION 3.24)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_base LANGUAGES CXX)

if(NOT TARGET telar-client)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../telar-client" "${CMAKE_BINARY_DIR}/telar-client")
endif()

add_library(telar-base INTERFACE)
add_library(telar::base ALIAS telar-base)
target_compile_features(telar-base INTERFACE cxx_std_23)
target_include_directories(telar-base INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(telar-base INTERFACE telar::client)

telar_editor_flags(telar-base)
