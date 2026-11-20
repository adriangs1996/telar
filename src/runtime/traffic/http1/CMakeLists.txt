telar_add_domain(runtime traffic/http1
  SOURCES
    head/head.cpp)

if(BUILD_TESTING)
  telar_add_domain_tests(traffic/http1)
endif()
