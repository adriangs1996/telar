telar_add_domain(cli commands/hook
  SOURCES
    hook.cpp
  DEPS session/control_session commands/worktree_git commands/hooks console/command_limit)

if(BUILD_TESTING)
  telar_add_domain_tests(commands/hook LINK telar::base telar::platform telar::wire)
endif()
