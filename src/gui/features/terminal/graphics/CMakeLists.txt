telar_add_domain(gui features/terminal/graphics
  SOURCES
    graphics.cpp
    graphics-artwork.cpp
    graphics-pauses.cpp
    graphics-placement.cpp
    graphics-residency.cpp
    graphics-store.cpp
  DEPS foundation/core foundation/text foundation/terminal foundation/model)

if(BUILD_TESTING)
  telar_add_domain_tests(features/terminal/graphics TIMEOUT 30)
endif()
