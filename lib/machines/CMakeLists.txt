cmake_minimum_required(VERSION 4.4.5)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_machines LANGUAGES CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/TelarTargets.cmake")

if(NOT TARGET telar-client)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../client" "${CMAKE_BINARY_DIR}/telar-client")
endif()

telar_add_library(telar-machines
  SOURCES machines.cpp
  INCLUDES "${CMAKE_CURRENT_SOURCE_DIR}/include"
  DEPS telar::client)

telar_editor_flags(telar-machines)
