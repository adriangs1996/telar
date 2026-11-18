telar_add_domain(gui features/paths
  SOURCES
    paths.cpp
    paths-presentation.cpp
  DEPS foundation/core foundation/text foundation/terminal foundation/keys)

if(BUILD_TESTING)
  telar_add_domain_tests(features/paths)
endif()
