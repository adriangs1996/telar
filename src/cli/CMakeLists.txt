cmake_minimum_required(VERSION 4.4.5)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
set(CMAKE_OSX_DEPLOYMENT_TARGET "26.0" CACHE STRING "Minimum supported macOS version")
project(telar_cli LANGUAGES C CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/TelarTargets.cmake")

if(NOT TARGET telar-config)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../../lib/config" "${CMAKE_BINARY_DIR}/telar-config")
endif()
if(NOT TARGET telar-tls)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../../lib/tls" "${CMAKE_BINARY_DIR}/telar-tls")
endif()
if(NOT TARGET telar-machines)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../../lib/machines" "${CMAKE_BINARY_DIR}/telar-machines")
endif()
if(NOT TARGET telar-render)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../../lib/render" "${CMAKE_BINARY_DIR}/telar-render")
endif()
if(NOT TARGET telar-git-checkout)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../../lib/git/checkout" "${CMAKE_BINARY_DIR}/telar-git-checkout")
endif()

find_package(Threads REQUIRED)
find_package(Python3 REQUIRED COMPONENTS Interpreter)

file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/generated")
include(cmake/integration.cmake)
include(cmake/help.cmake)
include(cmake/machines.cmake)

# `hook` runs on every agent event, so the CLI links only libcrypto beside the system
# libraries: no libssl, frameworks, SQLite, pcap or the runtime's terminal engine.
add_library(cli-core STATIC
  command_limit/command_limit.cpp
  control_session/control_session.cpp
  control_session/runtime_connection.cpp
  history/history.cpp
  hook/hook.cpp
  hooks/command/command.cpp
  hooks/session/session.cpp
  integration/settings/integration.cpp
  integration/settings/settings.cpp
  machine/machine.cpp
  machine_ssh/machine_ssh.cpp
  output/output.cpp
  plugin/plugin.cpp
  project_setup/project_setup.cpp
  render/render.cpp
  runtime_observer/runtime_observer.cpp
  server/server.cpp
  tab/tab.cpp
  window/core.cpp
  worktree/worktree.cpp
  worktree_git/worktree_git.cpp
)
telar_modules(cli-core)
set_target_properties(cli-core telar-platform PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_include_directories(cli-core PUBLIC "${CMAKE_CURRENT_BINARY_DIR}/generated")
target_link_libraries(cli-core PUBLIC telar::config telar::tls telar::machines telar::render telar::git-checkout Threads::Threads)
target_compile_options(cli-core PUBLIC -Wall -Wextra -Wpedantic)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_compile_definitions(cli-core PUBLIC _GNU_SOURCE)
endif()

# Machines, CLI installation and window startup.
if(TELAR_LINKED_SQLITE)
  target_link_libraries(cli-core PUBLIC deps::sqlite3)
  target_compile_definitions(cli-core PUBLIC TELAR_LINKED_SQLITE=1)
endif()

add_library(cli-launch STATIC launch_commands/launch_commands.cpp launch_commands/completions.cpp)
target_link_libraries(cli-launch PUBLIC cli-core)
if(NOT TARGET ebnf-core)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../../lib/ebnf" "${CMAKE_BINARY_DIR}/ebnf")
endif()
# `completions check` compiles a spec with the matcher the runtime uses.
target_link_libraries(cli-launch PRIVATE ebnf::ebnf)

add_executable(telar main.cpp)
target_link_libraries(telar PRIVATE cli-core cli-launch)
# Nothing loads symbols from telar. Exporting none spares dyld from coalescing
# every weak template instantiation against libc++ on each start, which
# `hook` pays per agent event.
if(APPLE)
  target_link_options(telar PRIVATE "LINKER:-exported_symbol,__mh_execute_header")
endif()
include(cmake/window.cmake)
install(TARGETS telar RUNTIME DESTINATION bin)
telar_register_checks(cli-core cli-launch telar telar-config-check CHECKS ${TELAR_CHECKS})

include(CTest)
if(BUILD_TESTING)
  add_subdirectory(tests)
endif()
