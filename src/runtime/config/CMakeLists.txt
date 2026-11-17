telar_add_domain(runtime config
  SOURCES
    loader/loader.cpp)

if(BUILD_TESTING)
  telar_add_domain_tests(config LINK telar::config telar::lua telar::platform)
endif()
