telar_add_domain(runtime transport
  SOURCES
    connection/connection.cpp)

if(BUILD_TESTING)
  telar_add_domain_tests(transport LINK telar::base telar::client telar::platform telar::wire)
endif()
