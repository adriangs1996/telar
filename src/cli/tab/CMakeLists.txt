telar_add_domain(cli tab
  SOURCES
    tab.cpp
  DEPS output command_limit worktree_git window)

if(BUILD_TESTING)
  telar_add_domain_tests(tab)
endif()
