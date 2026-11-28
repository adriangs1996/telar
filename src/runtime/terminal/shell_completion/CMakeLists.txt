telar_add_domain(runtime terminal/shell_completion
  SOURCES
    remote/remote.cpp
    shell_completion.cpp
  DEPS workers terminal/shell_integration)
# The commands a host `ssh` reached runs are encoded at compile time, which takes more steps than
# the compiler allows by default.
set_source_files_properties(remote/remote.cpp PROPERTIES COMPILE_OPTIONS "-fconstexpr-steps=16777216")

if(BUILD_TESTING)
  telar_add_domain_tests(terminal/shell_completion LINK telar::base telar::platform telar::wire)
endif()
