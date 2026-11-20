telar_add_domain(runtime agents/observation
  SOURCES
    processor/processor.cpp
  DEPS diagnostics host workers terminal/shell_integration terminal history terminal/command_capture agents)

if(BUILD_TESTING)
  telar_add_domain_tests(agents/observation LINK telar::base telar::config telar::platform telar::wire)
endif()
