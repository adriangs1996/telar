# The domains of network traffic live below this one, which is their control surface: outside
# src/runtime/traffic only the modules of public_modules (docs/build/modules.json) are imported.
telar_add_domain(runtime traffic
  EXCLUDE tap http1 http exchange_capture http2 tls redirect proxy
  SOURCES
    capture/capture.cpp
    capture_analysis/capture_analysis.cpp
    control_backend/control_backend.cpp
    control_protocol/control_protocol.cpp
  DEPS host traffic/tap traffic/http traffic/redirect)

if(BUILD_TESTING)
  telar_add_domain_tests(traffic LINK telar::base telar::platform telar::vocabulary telar::wire telar-tls-tests-support)
endif()
