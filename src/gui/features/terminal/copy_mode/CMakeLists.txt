telar_add_domain(gui features/terminal/copy_mode
  SOURCES
    copy_mode.cpp
    copy_mode-mode.cpp
    copy_mode-pointer.cpp
    copy_mode-state.cpp
  DEPS foundation/terminal foundation/actions foundation/keys)

if(BUILD_TESTING)
  telar_add_domain_tests(features/terminal/copy_mode TIMEOUT 30)
endif()
