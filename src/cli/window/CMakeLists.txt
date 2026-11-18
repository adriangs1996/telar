telar_add_domain(cli window
  SOURCES
    core.cpp
  DEPS output command_limit plugin)

if(BUILD_TESTING)
  telar_add_domain_tests(window LINK telar::base)
endif()
