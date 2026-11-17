telar_add_domain(cli worktree
  SOURCES
    worktree.cpp
  DEPS output command_limit control_session worktree_git history project_setup machine_ssh tab)

if(BUILD_TESTING)
  telar_add_domain_tests(worktree LINK telar::base)
endif()
