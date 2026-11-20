telar_add_domain(cli commands/worktree_git
  SOURCES
    worktree_git.cpp
  DEPS console/output console/command_limit session/control_session session/runtime_observer session/server)

if(BUILD_TESTING)
  telar_add_domain_tests(commands/worktree_git LINK telar::base)
endif()
