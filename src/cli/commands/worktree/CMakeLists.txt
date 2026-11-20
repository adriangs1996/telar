telar_add_domain(cli commands/worktree
  SOURCES
    worktree.cpp
  DEPS console/output console/command_limit session/control_session commands/worktree_git commands/history commands/project_setup commands/machine_ssh commands/tab)

if(BUILD_TESTING)
  telar_add_domain_tests(commands/worktree LINK telar::base)
endif()
