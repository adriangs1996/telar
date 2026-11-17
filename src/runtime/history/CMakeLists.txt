telar_add_domain(runtime history
  SOURCES
    event/event.cpp
    store/database.cpp
    store/store.cpp
  DEPS diagnostics transport platform)

if(BUILD_TESTING)
  telar_add_domain_tests(history LINK telar::base telar::config telar::platform telar::wire)
endif()
