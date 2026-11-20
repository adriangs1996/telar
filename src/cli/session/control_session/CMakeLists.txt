telar_add_domain(cli session/control_session
  SOURCES
    control_session.cpp
    runtime_connection.cpp
  DEPS console/output)

if(BUILD_TESTING)
  telar_add_domain_tests(session/control_session LINK telar::base telar::platform)
endif()
