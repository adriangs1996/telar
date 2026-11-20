telar_add_domain(runtime traffic/proxy
  SOURCES
    authenticate/authenticate.cpp
    client_configuration/client_configuration.cpp
    http2_capture_streams/http2_capture_streams.cpp
    intercepted_relay/intercepted_relay.cpp
    runtime/runtime.cpp
  DEPS host traffic/tap traffic/http1 traffic/http traffic/exchange_capture traffic/http2 traffic/tls traffic/redirect traffic)

if(BUILD_TESTING)
  telar_add_domain_tests(traffic/proxy LINK telar::base telar::config telar::lua telar::platform telar::plugins telar::tls telar::vocabulary telar::wire telar-tls-tests-support runtime-traffic-tls-tests-support runtime-traffic-http2-tests-support runtime-traffic-tests-support)
endif()
