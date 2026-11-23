telar_add_domain(cli commands/machine
  SOURCES
    machine.cpp
  DEPS console/command_error console/command_limit session/control_session session/runtime_observer session/server commands/integration commands/plugin commands/window
       commands/machine_gateway)

if(BUILD_TESTING)
  telar_add_domain_tests(commands/machine LINK telar::base)
endif()
