telar_add_domain(runtime agents
  SOURCES
    description_generator/description_generator.cpp
    screen_inference/screen_inference.cpp
    snapshot/snapshot.cpp
  DEPS platform terminal history)

if(BUILD_TESTING)
  telar_add_domain_tests(agents LINK telar::base telar::config telar::platform telar::wire)
endif()
