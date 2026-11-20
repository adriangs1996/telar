telar_add_domain(cli commands/tab
  SOURCES
    tab.cpp
  DEPS console/output console/command_limit commands/worktree_git commands/window)

if(BUILD_TESTING)
  telar_add_domain_tests(commands/tab)
endif()
