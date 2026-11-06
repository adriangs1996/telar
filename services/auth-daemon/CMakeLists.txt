cmake_minimum_required(VERSION 3.25)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
set(CMAKE_OSX_DEPLOYMENT_TARGET "26.0" CACHE STRING "Minimum supported macOS version")
project(telar_auth_daemon LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(TELAR_AUTH_WARNINGS_AS_ERRORS "Treat compiler warnings as errors" OFF)
option(TELAR_AUTH_SANITIZERS "Enable address and undefined behavior sanitizers" OFF)

if(NOT APPLE AND NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
  message(FATAL_ERROR "The auth daemon supports macOS and Linux")
endif()

add_executable(telar-auth-daemon main.cpp)
target_compile_options(telar-auth-daemon PRIVATE -Wall -Wextra -Wpedantic)
target_compile_definitions(telar-auth-daemon PRIVATE TELAR_DEBUG=$<CONFIG:Debug>)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_compile_definitions(telar-auth-daemon PRIVATE _GNU_SOURCE)
endif()
if(TELAR_AUTH_WARNINGS_AS_ERRORS)
  target_compile_options(telar-auth-daemon PRIVATE -Werror)
endif()
if(TELAR_AUTH_SANITIZERS)
  if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    message(FATAL_ERROR "TELAR_AUTH_SANITIZERS requires GCC or Clang")
  endif()
  target_compile_options(telar-auth-daemon PRIVATE -fsanitize=address,undefined -fno-omit-frame-pointer)
  target_link_options(telar-auth-daemon PRIVATE -fsanitize=address,undefined)
endif()

install(TARGETS telar-auth-daemon RUNTIME DESTINATION bin)

include(CTest)
if(BUILD_TESTING)
  add_test(NAME auth-daemon-smoke COMMAND telar-auth-daemon)
  set_tests_properties(auth-daemon-smoke PROPERTIES TIMEOUT 10)
endif()

# Reuse the generic compilation-database and formatting tooling, without linking TBC.
get_filename_component(auth_compiler_directory "${CMAKE_CXX_COMPILER}" DIRECTORY)
foreach(mode IN ITEMS format format-check lint)
  add_custom_target(${mode}
    COMMAND "${CMAKE_COMMAND}"
      "-DMODE=${mode}"
      "-DSOURCE_DIR=${CMAKE_CURRENT_SOURCE_DIR}"
      "-DBINARY_DIR=${CMAKE_CURRENT_BINARY_DIR}"
      "-DCOMPILER_DIR=${auth_compiler_directory}"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/../../dlls/tbc/cmake/tooling.cmake"
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    USES_TERMINAL
    VERBATIM)
endforeach()
