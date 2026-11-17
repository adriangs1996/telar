telar_add_domain(gui features/machines
  SOURCES
    machines-discovery.cpp
    machines-presentation.cpp
    machines-profiles.cpp
    machines-roster.cpp
  DEPS foundation/core foundation/text foundation/model)

if(BUILD_TESTING)
  telar_add_domain_tests(features/machines)
endif()
