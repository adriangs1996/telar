telar_process(cli OPTIONS ${TELAR_WARNINGS})

find_package(Threads REQUIRED)
find_package(Python3 REQUIRED COMPONENTS Interpreter)

file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/generated")
include(cmake/integration.cmake)
include(cmake/help.cmake)
include(cmake/machines.cmake)

# What every domain of the CLI compiles and links with. `hook` runs on every agent event,
# so the CLI links only libcrypto beside the system libraries: no libssl, frameworks,
# SQLite, pcap or the runtime's terminal engine.
target_include_directories(cli-settings INTERFACE "${CMAKE_CURRENT_BINARY_DIR}/generated")
target_link_libraries(cli-settings INTERFACE telar::config telar::tls telar::machines telar::render telar::git-checkout Threads::Threads)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_compile_definitions(cli-settings INTERFACE _GNU_SOURCE)
endif()

# Machines, CLI installation and window startup. On Linux the CLI links the managed
# SQLite for history instead of loading whatever the system has.
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_link_libraries(cli-settings INTERFACE deps::sqlite3)
  target_compile_definitions(cli-settings INTERFACE TELAR_LINKED_SQLITE=1)
endif()

# The domains of docs/build/modules.json (process_layers), lowest first.
foreach(domain IN ITEMS base output render command_limit control_session monitor runtime_observer server
    worktree_git history hooks integration plugin project_setup window hook machine_ssh tab worktree
    machine launch_commands)
  add_subdirectory(${domain})
endforeach()

# The launch commands' bodies, which only telar links.
add_library(cli-launch STATIC launch_commands/launch_commands.cpp launch_commands/completions.cpp)
target_link_libraries(cli-launch PUBLIC cli-output cli-server cli-plugin cli-window cli-machine_ssh cli-machine cli-launch_commands)
# `completions check` compiles a spec with the matcher the runtime uses.
target_link_libraries(cli-launch PRIVATE ebnf::ebnf)

add_executable(telar main.cpp)
target_link_libraries(telar PRIVATE cli-base cli-output cli-render cli-command_limit cli-control_session cli-monitor
  cli-runtime_observer cli-server cli-worktree_git cli-history cli-hooks cli-integration cli-plugin
  cli-project_setup cli-window cli-hook cli-tab cli-worktree cli-launch_commands cli-launch)
# Nothing loads symbols from telar. Exporting none spares dyld from coalescing
# every weak template instantiation against libc++ on each start, which
# `hook` pays per agent event.
if(APPLE)
  target_link_options(telar PRIVATE "LINKER:-exported_symbol,__mh_execute_header")
endif()
include(cmake/window.cmake)
install(TARGETS telar RUNTIME DESTINATION bin)
# `telar server` and the endpoint discovery start the runtime installed beside the CLI,
# and panes get the CLI beside the runtime, so both build into the same directory.
if(TARGET telar-runtime)
  get_target_property(telar_runtime_directory telar-runtime BINARY_DIR)
  set_target_properties(telar PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${telar_runtime_directory}")
endif()
telar_register_checks(cli-launch telar telar-config-check CHECKS ${TELAR_CHECKS})

if(BUILD_TESTING)
  add_subdirectory(tests)
endif()
