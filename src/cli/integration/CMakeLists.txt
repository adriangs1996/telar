telar_add_domain(cli integration
  SOURCES
    settings/integration.cpp
    settings/settings.cpp
  DEPS base)

if(BUILD_TESTING)
  telar_add_domain_tests(integration LINK telar::base)
endif()
