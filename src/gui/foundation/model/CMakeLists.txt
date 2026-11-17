telar_add_domain(gui foundation/model
  SOURCES
    model-pane_layout.cpp
    model-records.cpp
    model-replicas.cpp
  DEPS foundation/core)

if(BUILD_TESTING)
  telar_add_domain_tests(foundation/model)
endif()
