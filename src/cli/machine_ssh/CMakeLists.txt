telar_add_domain(cli machine_ssh
  SOURCES
    machine_ssh.cpp
  DEPS base output command_limit control_session server plugin)

if(BUILD_TESTING)
  telar_add_domain_tests(machine_ssh LINK telar::base)
endif()
