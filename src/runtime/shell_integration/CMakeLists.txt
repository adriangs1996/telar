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
