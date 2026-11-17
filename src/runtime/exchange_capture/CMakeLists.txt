telar_add_domain(runtime exchange_capture
  SOURCES
    pipeline/pipeline.cpp
    producer/producer.cpp
  DEPS platform vocabulary http)

if(BUILD_TESTING)
  telar_add_domain_tests(exchange_capture LINK telar::base telar::config telar::platform)
endif()
