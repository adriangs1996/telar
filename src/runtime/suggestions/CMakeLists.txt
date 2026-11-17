telar_add_domain(runtime suggestions
  SOURCES
    engine/engine.cpp
  DEPS transport)

if(BUILD_TESTING)
  telar_add_domain_tests(suggestions LINK telar::base telar::platform telar::wire)
endif()
