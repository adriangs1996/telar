cmake_minimum_required(VERSION 4.4.5)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
set(CMAKE_OSX_DEPLOYMENT_TARGET "26.0" CACHE STRING "Minimum supported macOS version")
project(telar_auth_daemon LANGUAGES CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/cpp_modules.cmake")

option(TELAR_AUTH_WARNINGS_AS_ERRORS "Treat compiler warnings as errors" OFF)

if(NOT APPLE AND NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
  message(FATAL_ERROR "The auth daemon supports macOS and Linux")
endif()

add_executable(telar-auth-daemon main.cpp)
target_compile_options(telar-auth-daemon PRIVATE -Wall -Wextra -Wpedantic)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_compile_definitions(telar-auth-daemon PRIVATE _GNU_SOURCE)
endif()
if(TELAR_AUTH_WARNINGS_AS_ERRORS)
  target_compile_options(telar-auth-daemon PRIVATE -Werror)
endif()
install(TARGETS telar-auth-daemon RUNTIME DESTINATION bin)

include(CTest)
if(BUILD_TESTING)
  add_test(NAME auth-daemon-smoke COMMAND telar-auth-daemon)
  set_tests_properties(auth-daemon-smoke PROPERTIES TIMEOUT 10)
endif()

# Reuse the generic compilation-database and formatting tooling, without linking TBC.
get_filename_component(auth_compiler_directory "${CMAKE_CXX_COMPILER}" DIRECTORY)
foreach(mode IN ITEMS format format-check lint lifetime-check)
  add_custom_target(${mode}
    COMMAND "${CMAKE_COMMAND}"
      "-DMODE=${mode}"
      "-DSOURCE_DIR=${CMAKE_CURRENT_SOURCE_DIR}"
      "-DBINARY_DIR=${CMAKE_CURRENT_BINARY_DIR}"
      "-DCOMPILER_DIR=${auth_compiler_directory}"
      "-DTBC_LINTER=${TBC_LINTER}"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/../../lib/tbc/cmake/tooling.cmake"
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    USES_TERMINAL
    VERBATIM)
endforeach()
# The lifetime check reads the BMIs the build produces.
add_dependencies(lifetime-check telar-auth-daemon)
