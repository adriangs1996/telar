telar_add_domain(runtime core/persistence
  SOURCES
    session_store/session_store.cpp
  DEPS workers terminal agents core/model)

if(BUILD_TESTING)
  telar_add_domain_tests(core/persistence LINK telar::base telar::platform telar::wire)
endif()
