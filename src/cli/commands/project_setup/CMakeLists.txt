telar_add_domain(cli commands/project_setup
  SOURCES
    project_setup.cpp
  DEPS console/command_error console/output console/command_limit session/control_session session/runtime_observer session/server commands/history commands/plugin)

if(BUILD_TESTING)
  telar_add_domain_tests(commands/project_setup LINK telar::base)
endif()
