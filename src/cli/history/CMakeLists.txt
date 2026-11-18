telar_add_domain(cli history
  SOURCES
    history.cpp
  DEPS command_limit control_session runtime_observer server)

if(BUILD_TESTING)
  telar_add_domain_tests(history LINK telar::base)
endif()
