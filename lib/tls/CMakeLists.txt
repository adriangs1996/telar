cmake_minimum_required(VERSION 4.4.5)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_tls LANGUAGES CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/TelarTargets.cmake")

if(NOT TARGET telar-platform)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../platform" "${CMAKE_BINARY_DIR}/telar-platform")
endif()

include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/openssl.cmake")

telar_add_library(telar-tls
  SOURCES tls.cpp
  INCLUDES "${CMAKE_CURRENT_SOURCE_DIR}/include"
  DEPS telar::platform OpenSSL::SSL OpenSSL::Crypto)

telar_editor_flags(telar-tls)
