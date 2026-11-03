cmake_minimum_required(VERSION 3.24)
project(telar_tls LANGUAGES CXX)

if(NOT TARGET telar-config)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../telar-config" "${CMAKE_BINARY_DIR}/telar-config")
endif()

find_package(OpenSSL 3.0...<4.0 REQUIRED COMPONENTS SSL Crypto)

add_library(telar-tls INTERFACE)
add_library(telar::tls ALIAS telar-tls)
target_include_directories(telar-tls INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(telar-tls INTERFACE telar::config OpenSSL::SSL OpenSSL::Crypto)
