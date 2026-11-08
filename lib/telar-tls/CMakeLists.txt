cmake_minimum_required(VERSION 4.4.5)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_tls LANGUAGES CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/cpp_modules.cmake")

if(NOT TARGET telar-config)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../telar-config" "${CMAKE_BINARY_DIR}/telar-config")
endif()

include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/openssl.cmake")

add_library(telar-tls STATIC)
add_library(telar::tls ALIAS telar-tls)
telar_modules(telar-tls)
target_include_directories(telar-tls PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(telar-tls PUBLIC telar::config OpenSSL::SSL OpenSSL::Crypto)

telar_editor_flags(telar-tls GHOSTTY)
