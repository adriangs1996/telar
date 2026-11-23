telar_add_domain(gui features/explorer
  SOURCES
    explorer-cache.cpp
    explorer-keys.cpp
    explorer-presentation.cpp
    explorer-view.cpp
  DEPS foundation/keys)

if(BUILD_TESTING)
  telar_add_domain_tests(features/explorer)
endif()
