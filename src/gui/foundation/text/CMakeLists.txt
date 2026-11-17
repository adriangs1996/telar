telar_add_domain(gui foundation/text
  SOURCES
    text-bounded_editor.cpp
    text-tab_caption.cpp
    text-text_fit.cpp
  DEPS foundation/core)

if(BUILD_TESTING)
  telar_add_domain_tests(foundation/text)
  target_compile_options(gui-foundation-text-tests PRIVATE -ffp-contract=off)
endif()
