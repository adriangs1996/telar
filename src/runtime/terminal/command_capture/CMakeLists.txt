telar_add_domain(runtime terminal/command_capture
  SOURCES
    tracker/tracker.cpp
  DEPS diagnostics terminal/shell_integration terminal history)

if(BUILD_TESTING)
  telar_add_domain_tests(terminal/command_capture LINK telar::base telar::platform telar::wire)
endif()
