telar_add_domain(runtime proxy
  SOURCES
    authenticate/authenticate.cpp
    http2_capture_streams/http2_capture_streams.cpp
    intercepted_relay/intercepted_relay.cpp
    runtime/runtime.cpp
  DEPS platform vocabulary http1 http exchange_capture http2 tls redirect traffic)

if(BUILD_TESTING)
  telar_add_domain_tests(proxy LINK telar::base telar::config telar::lua telar::platform telar::plugins telar::tls telar::vocabulary telar::wire telar-tls-tests-support runtime-http2-tests-support runtime-traffic-tests-support)
endif()
