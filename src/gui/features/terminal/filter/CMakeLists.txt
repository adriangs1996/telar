telar_add_domain(gui features/terminal/filter
  SOURCES
    filter.cpp
    filter-lines.cpp
  DEPS foundation/terminal)

if(BUILD_TESTING)
  telar_add_domain_tests(features/terminal/filter)
endif()
