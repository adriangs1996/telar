telar_add_domain(cli commands/machine_gateway
  SOURCES
    machine_gateway.cpp
  DEPS console/command_error console/output console/command_limit session/control_session session/server commands/plugin)

if(BUILD_TESTING)
  telar_add_domain_tests(commands/machine_gateway LINK telar::base)
endif()
