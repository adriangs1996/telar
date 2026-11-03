cmake_minimum_required(VERSION 3.24)
set(CMAKE_OSX_DEPLOYMENT_TARGET "26.0" CACHE STRING "Minimum supported macOS version")
project(telar_cli LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(NOT TARGET telar-tls)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../../dlls/telar-tls" "${CMAKE_BINARY_DIR}/telar-tls")
endif()

find_package(Threads REQUIRED)

file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/generated")
include(cmake/integration.cmake)

# `hook` runs on every agent event, so the CLI links only libcrypto beside the system
# libraries: no libssl, frameworks, SQLite, pcap or the runtime's terminal engine.
add_library(cli-core STATIC integration.cpp runtime_connection.cpp)
target_include_directories(cli-core PUBLIC "${CMAKE_CURRENT_BINARY_DIR}/generated")
target_link_libraries(cli-core PUBLIC telar::tls Threads::Threads)
target_compile_definitions(cli-core PUBLIC TELAR_DEBUG=$<CONFIG:Debug>)
target_compile_options(cli-core PUBLIC -Wall -Wextra -Wpedantic)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_compile_definitions(cli-core PUBLIC _GNU_SOURCE)
endif()

add_executable(telar main.cpp)
target_link_libraries(telar PRIVATE cli-core)
install(TARGETS telar RUNTIME DESTINATION bin)

include(CTest)
if(BUILD_TESTING)
  add_executable(hook-tests tests/hooks_test.cpp)
  target_link_libraries(hook-tests PRIVATE cli-core)
  add_test(NAME hook-tests COMMAND hook-tests)
  add_executable(integration-tests tests/integration_test.cpp)
  target_link_libraries(integration-tests PRIVATE cli-core)
  add_test(NAME integration-tests COMMAND integration-tests)
  add_executable(hook-mapping-probe tests/hook_mapping_probe.cpp)
  target_link_libraries(hook-mapping-probe PRIVATE cli-core)
endif()
