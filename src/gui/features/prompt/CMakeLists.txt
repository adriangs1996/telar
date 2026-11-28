telar_add_domain(gui features/prompt
  SOURCES
    prompt.cpp
    prompt-completion.cpp
    prompt-correction.cpp
    prompt-editor.cpp
    prompt-layout.cpp
    prompt-line.cpp
    prompt-menu.cpp
    prompt-ranking.cpp
    prompt-recall.cpp
    prompt-routing.cpp
    prompt-specs.cpp
    prompt-text.cpp
  DEPS foundation/core foundation/text foundation/keys)

if(BUILD_TESTING)
  telar_add_domain_tests(features/prompt)
endif()
