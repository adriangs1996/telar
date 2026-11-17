telar_add_domain(gui features/workbench
  SOURCES
    workbench.cpp
    workbench-chrome.cpp
    workbench-layouts.cpp
    workbench-motions.cpp
    workbench-progress.cpp
    workbench-tabs.cpp
  DEPS foundation/core foundation/text foundation/model foundation/agents foundation/drawing)

if(BUILD_TESTING)
  telar_add_domain_tests(features/workbench TIMEOUT 30)
endif()
