telar_add_domain(runtime workers
  SOURCES
    background_executor/background_executor.cpp
    request_worker/request_worker.cpp
  DEPS diagnostics transport suggestions host)

if(BUILD_TESTING)
  telar_add_domain_tests(workers LINK telar::base telar::wire)
endif()
