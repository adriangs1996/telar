telar_add_domain(cli server
  SOURCES
    server.cpp
  DEPS output control_session runtime_observer)

if(BUILD_TESTING)
  telar_add_domain_tests(server LINK telar::wire)
endif()
