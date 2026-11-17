telar_add_domain(runtime command_capture
  SOURCES
    tracker/tracker.cpp
  DEPS diagnostics shell_integration terminal history)

if(BUILD_TESTING)
  telar_add_domain_tests(command_capture LINK telar::base telar::platform telar::wire)
endif()
