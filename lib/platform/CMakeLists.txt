cmake_minimum_required(VERSION 4.4.5)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_platform LANGUAGES C CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/TelarTargets.cmake")

if(NOT TARGET telar-base)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../base" "${CMAKE_BINARY_DIR}/telar-base")
endif()
if(NOT TARGET telar-vocabulary)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../vocabulary" "${CMAKE_BINARY_DIR}/telar-vocabulary")
endif()
if(NOT TARGET telar-sys)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../sys" "${CMAKE_BINARY_DIR}/telar-sys")
endif()

find_package(Threads REQUIRED)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/openssl.cmake")

telar_add_library(telar-platform
  SOURCES primitives/primitives.cpp src/open_directory.c process/pipe_process.cpp process/pty_process.cpp src/trace.cpp daemon/daemon.cpp error/error.cpp events/events.cpp fs/fs.cpp graphics/graphics.cpp net/net.cpp sha256/sha256.cpp thread/thread.cpp paths/paths.cpp process/process.cpp
  INCLUDES "${CMAKE_CURRENT_SOURCE_DIR}/include"
  DEPS telar::base telar::sys telar::vocabulary OpenSSL::Crypto Threads::Threads ${CMAKE_DL_LIBS})
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_compile_definitions(telar-platform PRIVATE _GNU_SOURCE)
  target_link_libraries(telar-platform PUBLIC util)
endif()
target_compile_options(telar-platform PRIVATE -Wall -Wextra -Wpedantic)

telar_editor_flags(telar-platform)
