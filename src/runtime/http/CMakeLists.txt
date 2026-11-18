telar_add_domain(runtime http
  SOURCES
    content/content.cpp
    message/message.cpp
  DEPS vocabulary http1)

if(BUILD_TESTING)
  telar_add_domain_tests(http)
endif()
