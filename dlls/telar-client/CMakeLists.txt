cmake_minimum_required(VERSION 4.4.5)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_client LANGUAGES CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/cpp_modules.cmake")

if(NOT TARGET telar-base)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../telar-base" "${CMAKE_BINARY_DIR}/telar-base")
endif()

add_library(telar-client STATIC)
add_library(telar::client ALIAS telar-client)
telar_modules(telar-client)
target_compile_features(telar-client PUBLIC cxx_std_23)
target_link_libraries(telar-client PUBLIC telar::base)
target_include_directories(telar-client PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")

telar_editor_flags(telar-client)
