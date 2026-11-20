telar_add_domain(runtime traffic/tap
  SOURCES
    exchange/exchange.cpp
    frames/frames.cpp
    protocol/protocol.cpp)

if(BUILD_TESTING)
  telar_add_domain_tests(traffic/tap LINK telar::base telar::config telar::plugins telar::wire)
endif()
