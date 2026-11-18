telar_add_domain(cli worktree_git
  SOURCES
    worktree_git.cpp
  DEPS output command_limit control_session runtime_observer server)

if(BUILD_TESTING)
  telar_add_domain_tests(worktree_git LINK telar::base)
endif()
