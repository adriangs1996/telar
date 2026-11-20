telar_add_domain(runtime traffic/http2
  SOURCES
    direction_observer/direction_observer.cpp
    frame_reader/frame_reader.cpp
  DEPS traffic/http1 traffic/http)

if(BUILD_TESTING)
  telar_add_domain_tests(traffic/http2)
endif()
