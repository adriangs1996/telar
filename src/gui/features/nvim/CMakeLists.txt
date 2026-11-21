telar_add_domain(gui features/nvim
  SOURCES
    nvim.cpp
  DEPS foundation/core foundation/terminal)

if(BUILD_TESTING)
  telar_add_domain_tests(features/nvim LINK telar::base telar::wire)
endif()
