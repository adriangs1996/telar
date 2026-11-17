telar_add_domain(runtime http1
  SOURCES
    head/head.cpp)

if(BUILD_TESTING)
  telar_add_domain_tests(http1)
endif()
