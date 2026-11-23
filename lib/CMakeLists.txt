# Every library, in the topological order of library_layers in docs/build/modules.json:
# a library comes after the ones it links.

# The telar-base package installs with the telar.tbc annotations and the telar.sys
# modules it imports: cmake --install <tree> --component telar-base.
set(CMAKE_INSTALL_DEFAULT_COMPONENT_NAME telar-base)
add_subdirectory(tbc)
add_subdirectory(sys)
add_subdirectory(base)
set(CMAKE_INSTALL_DEFAULT_COMPONENT_NAME telar)

add_subdirectory(vocabulary)
add_subdirectory(ghostty)
add_subdirectory(native)
add_subdirectory(clipboard)
add_subdirectory(shell)
add_subdirectory(ebnf)
add_subdirectory(wire)
add_subdirectory(client)
add_subdirectory(lua)
add_subdirectory(render)
add_subdirectory(msgpack)
add_subdirectory(platform)
add_subdirectory(machines)
add_subdirectory(git)
add_subdirectory(tls)
add_subdirectory(remote)
add_subdirectory(plugins)
add_subdirectory(config)

if(BUILD_TESTING)
  add_subdirectory(testing)
endif()
