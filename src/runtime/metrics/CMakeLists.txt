telar_add_domain(runtime metrics
  SOURCES
    host_sampler/host_sampler.cpp
    monitor/monitor.cpp
  DEPS diagnostics host)

if(BUILD_TESTING)
  telar_add_domain_tests(metrics LINK telar::base telar::wire)
endif()
