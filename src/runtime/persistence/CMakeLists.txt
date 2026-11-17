telar_add_domain(runtime persistence
  SOURCES
    session_store/session_store.cpp
  DEPS platform terminal agents model)

if(BUILD_TESTING)
  telar_add_domain_tests(persistence LINK telar::base telar::platform telar::wire)
endif()
