# telar-client has no textual headers: the telar_wire/ headers it includes are telar-wire's.
telar_add_library(telar-client
  SOURCES client.cpp
  DEPS telar::base telar::sys telar::vocabulary telar::wire)

if(BUILD_TESTING)
  telar_add_tests(telar-client-tests LABEL lib.client LINK telar::client telar::platform telar::base)
endif()
