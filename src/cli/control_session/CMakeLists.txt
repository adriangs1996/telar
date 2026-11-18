telar_add_domain(cli control_session
  SOURCES
    control_session.cpp
    runtime_connection.cpp)

if(BUILD_TESTING)
  telar_add_domain_tests(control_session LINK telar::base telar::platform)
endif()
