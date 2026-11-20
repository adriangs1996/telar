telar_add_domain(cli commands/window
  SOURCES
    core.cpp
  DEPS console/output console/command_limit commands/plugin)

if(BUILD_TESTING)
  telar_add_domain_tests(commands/window LINK telar::base)
endif()
