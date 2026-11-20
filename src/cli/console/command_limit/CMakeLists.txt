telar_add_domain(cli console/command_limit
  SOURCES
    command_limit.cpp
  DEPS console/output)

if(BUILD_TESTING)
  telar_add_domain_tests(console/command_limit LINK telar::base)
endif()
