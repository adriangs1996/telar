telar_add_domain(gui features/terminal/input
  SOURCES
    input-child_mouse.cpp
    input-mouse_encoder.cpp
  DEPS foundation/core)

if(BUILD_TESTING)
  telar_add_domain_tests(features/terminal/input TIMEOUT 30)
endif()
