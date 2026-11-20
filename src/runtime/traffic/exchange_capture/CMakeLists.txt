telar_add_domain(runtime traffic/exchange_capture
  SOURCES
    pipeline/pipeline.cpp
    producer/producer.cpp
  DEPS workers traffic/tap traffic/http)

if(BUILD_TESTING)
  telar_add_domain_tests(traffic/exchange_capture LINK telar::base telar::config telar::platform)
endif()
