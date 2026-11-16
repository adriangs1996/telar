cmake_minimum_required(VERSION 4.4.5)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_sys LANGUAGES CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/TelarTargets.cmake")

find_package(Threads REQUIRED)

telar_add_library(telar-sys
  SOURCES posix/posix.cpp process/process.cpp socket/socket.cpp
  # The libraries that define what the modules declare.
  DEPS Threads::Threads ${CMAKE_DL_LIBS})
if(APPLE)
  target_sources(telar-sys PRIVATE apple/apple.cpp)
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_sources(telar-sys PRIVATE linux_api/linux_api.cpp)
endif()
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_compile_definitions(telar-sys PRIVATE _GNU_SOURCE)
  target_link_libraries(telar-sys PUBLIC util)
endif()
target_compile_options(telar-sys PRIVATE -Wall -Wextra -Wpedantic)

telar_editor_flags(telar-sys)

if(PROJECT_IS_TOP_LEVEL)
  include(CTest)
  if(BUILD_TESTING)
    add_executable(telar-sys-tests tests/sys_test.cpp)
    target_link_libraries(telar-sys-tests PRIVATE telar::sys)
    target_compile_options(telar-sys-tests PRIVATE -Wall -Wextra -Wpedantic)
    add_test(NAME telar-sys-tests COMMAND telar-sys-tests)
  endif()
endif()
