telar_add_domain(gui foundation/core
  SOURCES
    core-configuration.cpp
    core-geometry.cpp
    core-json_writer.cpp
    core-metric_levels.cpp
    core-motion.cpp
    core-terminal_size.cpp
    core-theme.cpp
    core-unicode_scalar.cpp)

if(BUILD_TESTING)
  telar_add_domain_tests(foundation/core)
endif()
