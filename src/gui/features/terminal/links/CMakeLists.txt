telar_add_domain(gui features/terminal/links
  SOURCES
    links.cpp
    links-editor.cpp
    links-pointer.cpp
    links-presentation.cpp
    links-text.cpp
  DEPS foundation/core foundation/text foundation/terminal)

if(BUILD_TESTING)
  telar_add_domain_tests(features/terminal/links TIMEOUT 30)
endif()
