telar_add_domain(runtime tls
  SOURCES
    interception/interception.cpp
    system_root_bundle/system_root_bundle.cpp
  DEPS platform)

if(BUILD_TESTING)
  telar_add_domain_tests(tls LINK telar::base telar::platform telar::tls telar-tls-tests-support)
endif()
