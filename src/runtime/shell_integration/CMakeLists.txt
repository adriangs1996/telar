telar_add_domain(runtime shell_integration
  SOURCES
    git_context/git_context.cpp
    shell_integration.cpp
    token/token.cpp
    words/words.cpp
  DEPS platform)
# The remote command `ssh` sends is encoded at compile time, which takes more steps than the
# compiler allows by default.
set_source_files_properties(shell_integration.cppm PROPERTIES COMPILE_OPTIONS "-fconstexpr-steps=16777216")
# words.cpp includes the completion specs the build generates.
add_dependencies(runtime-shell_integration command-specs)
# A spec is one string literal of up to ~115 KB, past the 64 KB the standard asks every compiler to
# accept; clang, the only compiler of this tree, takes it whole.
set_source_files_properties(words/words.cpp PROPERTIES COMPILE_OPTIONS "-Wno-overlength-strings")

if(BUILD_TESTING)
  telar_add_domain_tests(shell_integration LINK telar::base telar::platform telar::wire)
endif()
