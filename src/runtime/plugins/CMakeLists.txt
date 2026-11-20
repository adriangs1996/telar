telar_add_domain(runtime plugins
  SOURCES
    run_worker/run_worker.cpp
    service/service.cpp
    tap_configuration/tap_configuration.cpp
    worker/worker.cpp
  DEPS platform traffic/tap traffic/http traffic/redirect traffic)

if(BUILD_TESTING)
  telar_add_domain_tests(plugins LINK telar::base telar::config telar::platform telar::plugins telar::wire)
endif()
