cmake_minimum_required(VERSION 3.24)
project(telar_platform LANGUAGES C CXX)

if(NOT TARGET telar-base)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../telar-base" "${CMAKE_BINARY_DIR}/telar-base")
endif()

add_library(telar-platform STATIC src/file_descriptor.cpp src/open_directory.c)
add_library(telar::platform ALIAS telar-platform)
target_compile_features(telar-platform PUBLIC cxx_std_23)
target_include_directories(telar-platform PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(telar-platform PUBLIC telar::base)
target_compile_options(telar-platform PRIVATE -Wall -Wextra -Wpedantic)
