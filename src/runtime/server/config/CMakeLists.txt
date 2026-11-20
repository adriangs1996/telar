telar_add_domain(runtime server/config
  SOURCES
    loader/loader.cpp)

if(BUILD_TESTING)
  telar_add_domain_tests(server/config LINK telar::config telar::lua telar::platform)
endif()
