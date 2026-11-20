telar_add_domain(cli hook
  SOURCES
    hook.cpp
  DEPS control_session worktree_git hooks command_limit)

if(BUILD_TESTING)
  telar_add_domain_tests(hook LINK telar::base telar::platform telar::wire)
endif()
