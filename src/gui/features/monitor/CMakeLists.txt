telar_add_domain(gui features/monitor
  SOURCES
    monitor.cpp
    monitor-presentation.cpp)

if(BUILD_TESTING)
  telar_add_domain_tests(features/monitor)
endif()
