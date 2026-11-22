telar_add_domain(gui foundation/icons
  SOURCES
    icons.cpp)

if(BUILD_TESTING)
  telar_add_domain_tests(foundation/icons TIMEOUT 30)
endif()
