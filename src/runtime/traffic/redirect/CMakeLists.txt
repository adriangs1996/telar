telar_add_domain(runtime traffic/redirect
  SOURCES
    direction/direction.cpp
    ingress/ingress.cpp
    pf_rules/pf_rules.cpp
    socket_owners/socket_owners.cpp
  MACOS_SOURCES
    record/record.cpp
    record/record.cppm
  DEPS host traffic/tap)

if(BUILD_TESTING)
  telar_add_domain_tests(traffic/redirect LINK telar::base telar::config telar::platform telar::tls telar::wire)
endif()
