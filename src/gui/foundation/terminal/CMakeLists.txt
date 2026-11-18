telar_add_domain(gui foundation/terminal
  SOURCES
    terminal-copy_grid.cpp
    terminal-font_grid.cpp
    terminal-row_cache.cpp
    terminal-selection.cpp
  DEPS foundation/core)

if(BUILD_TESTING)
  telar_add_domain_tests(foundation/terminal)
endif()
