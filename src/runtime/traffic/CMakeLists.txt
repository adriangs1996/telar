telar_add_domain(runtime traffic
  SOURCES
    capture/capture.cpp
    capture_analysis/capture_analysis.cpp
    control_backend/control_backend.cpp
    control_protocol/control_protocol.cpp
  DEPS platform vocabulary http redirect)

if(BUILD_TESTING)
  telar_add_domain_tests(traffic LINK telar::base telar::platform telar::vocabulary telar::wire telar-tls-tests-support)
endif()
