telar_add_domain(runtime http2
  SOURCES
    direction_observer/direction_observer.cpp
    frame_reader/frame_reader.cpp
  DEPS http1 http)

if(BUILD_TESTING)
  telar_add_domain_tests(http2)
endif()
