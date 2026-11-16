cmake_minimum_required(VERSION 4.4.5)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_client LANGUAGES CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/TelarTargets.cmake")

if(NOT TARGET telar-base)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../base" "${CMAKE_BINARY_DIR}/telar-base")
endif()
if(NOT TARGET telar-sys)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../sys" "${CMAKE_BINARY_DIR}/telar-sys")
endif()
if(NOT TARGET telar-vocabulary)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../vocabulary" "${CMAKE_BINARY_DIR}/telar-vocabulary")
endif()
if(NOT TARGET telar-wire)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../wire" "${CMAKE_BINARY_DIR}/telar-wire")
endif()

# The telar_client/ textual headers are telar-wire's.
telar_add_library(telar-client
  SOURCES client.cpp
  DEPS telar::base telar::sys telar::vocabulary telar::wire)

telar_editor_flags(telar-client)
