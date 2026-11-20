telar_add_domain(runtime traffic/http
  SOURCES
    content/content.cpp
    message/message.cpp
  DEPS traffic/tap traffic/http1)

if(BUILD_TESTING)
  telar_add_domain_tests(traffic/http)
endif()
