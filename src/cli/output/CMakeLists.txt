telar_add_domain(cli output
  SOURCES
    output.cpp)

if(BUILD_TESTING)
  telar_add_domain_tests(output LINK telar::base)
endif()
