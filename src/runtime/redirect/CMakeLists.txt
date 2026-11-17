telar_add_domain(runtime redirect
  SOURCES
    direction/direction.cpp
    ingress/ingress.cpp
    pf_rules/pf_rules.cpp
    socket_owners/socket_owners.cpp
  MACOS_SOURCES
    record/record.cpp
    record/record.cppm
  DEPS platform vocabulary)

if(BUILD_TESTING)
  telar_add_domain_tests(redirect LINK telar::base telar::config telar::platform telar::tls telar::wire)
endif()
