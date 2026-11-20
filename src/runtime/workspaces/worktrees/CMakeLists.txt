telar_add_domain(runtime workspaces/worktrees
  SOURCES
    git_probe/git_probe.cpp
  DEPS workspaces)

if(BUILD_TESTING)
  telar_add_domain_tests(workspaces/worktrees LINK telar::base telar::platform telar::vocabulary)
endif()
