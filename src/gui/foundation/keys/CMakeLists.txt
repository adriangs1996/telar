telar_add_domain(gui foundation/keys
  SOURCES
    keys-configuration.cpp
    keys-key_encoder.cpp
  DEPS foundation/core foundation/text foundation/actions)

if(BUILD_TESTING)
  telar_add_domain_tests(foundation/keys TIMEOUT 30)
endif()
