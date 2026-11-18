telar_add_domain(cli project_setup
  SOURCES
    project_setup.cpp
  DEPS base output command_limit control_session runtime_observer server history plugin)

if(BUILD_TESTING)
  telar_add_domain_tests(project_setup LINK telar::base)
endif()
