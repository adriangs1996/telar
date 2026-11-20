telar_add_domain(cli session/server
  SOURCES
    server.cpp
  DEPS console/output console/command_limit session/control_session session/runtime_observer)

if(BUILD_TESTING)
  telar_add_domain_tests(session/server LINK telar::wire)
endif()
