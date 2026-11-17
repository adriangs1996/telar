telar_add_domain(gui foundation/forms
  SOURCES
    forms-form_field_geometry.cpp
    forms-history_match_highlight.cpp
    forms-name_prompt_geometry.cpp
    forms-suggestion_preview.cpp
  DEPS foundation/core foundation/text foundation/terminal foundation/drawing)

if(BUILD_TESTING)
  telar_add_domain_tests(foundation/forms)
endif()
