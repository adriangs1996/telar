telar_add_domain(runtime observation
  SOURCES
    processor/processor.cpp
  DEPS diagnostics platform shell_integration terminal history command_capture agents)

if(BUILD_TESTING)
  telar_add_domain_tests(observation LINK telar::base telar::config telar::platform telar::wire)
endif()
