telar_add_domain(cli command_limit
  SOURCES
    command_limit.cpp
  DEPS output)

if(BUILD_TESTING)
  telar_add_domain_tests(command_limit LINK telar::base)
endif()
