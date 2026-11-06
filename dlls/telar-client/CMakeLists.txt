cmake_minimum_required(VERSION 3.24)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_client LANGUAGES CXX)

if(NOT TARGET telar-base)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../telar-base" "${CMAKE_BINARY_DIR}/telar-base")
endif()

add_library(telar-client INTERFACE)
add_library(telar::client ALIAS telar-client)
target_compile_features(telar-client INTERFACE cxx_std_23)
target_link_libraries(telar-client INTERFACE telar::base)
target_include_directories(telar-client INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")

telar_editor_flags(telar-client)
