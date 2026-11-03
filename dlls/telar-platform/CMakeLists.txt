cmake_minimum_required(VERSION 3.24)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_platform LANGUAGES C CXX)

if(NOT TARGET telar-base)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../telar-base" "${CMAKE_BINARY_DIR}/telar-base")
endif()

find_package(Threads REQUIRED)

add_library(telar-platform STATIC src/file_descriptor.cpp src/open_directory.c src/pipe_process.cpp src/pty_process.cpp src/trace.cpp src/daemon.cpp)
add_library(telar::platform ALIAS telar-platform)
target_compile_features(telar-platform PUBLIC cxx_std_23)
target_include_directories(telar-platform PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(telar-platform PUBLIC telar::base Threads::Threads ${CMAKE_DL_LIBS})
target_compile_definitions(telar-platform PRIVATE TELAR_DEBUG=$<CONFIG:Debug>)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_compile_definitions(telar-platform PRIVATE _GNU_SOURCE)
  target_link_libraries(telar-platform PUBLIC util)
endif()
target_compile_options(telar-platform PRIVATE -Wall -Wextra -Wpedantic)

telar_editor_flags(telar-platform)
