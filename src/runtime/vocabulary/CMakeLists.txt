telar_add_domain(runtime vocabulary
  SOURCES
    exchange/exchange.cpp
    frames/frames.cpp
    traffic/traffic.cpp)

if(BUILD_TESTING)
  telar_add_domain_tests(vocabulary LINK telar::base telar::config telar::plugins telar::wire)
endif()
