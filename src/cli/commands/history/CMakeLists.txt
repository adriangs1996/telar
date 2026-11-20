telar_add_domain(cli commands/history
  SOURCES
    history.cpp
  DEPS console/command_limit session/control_session session/runtime_observer session/server)

if(BUILD_TESTING)
  telar_add_domain_tests(commands/history LINK telar::base)
endif()
