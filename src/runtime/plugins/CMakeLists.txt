telar_add_domain(runtime plugins
  SOURCES
    run_worker/run_worker.cpp
    service/service.cpp
    tap_configuration/tap_configuration.cpp
    worker/worker.cpp
  DEPS platform vocabulary http redirect traffic)
