telar_add_library(telar-shell SOURCES syntax/syntax.cpp)

if(BUILD_TESTING)
  add_executable(telar-shell-tests tests/syntax_test.cpp)
  target_link_libraries(telar-shell-tests PRIVATE telar::shell)
  target_compile_options(telar-shell-tests PRIVATE -Wall -Wextra -Wpedantic)
  add_test(NAME telar-shell-tests COMMAND telar-shell-tests)
  set_tests_properties(telar-shell-tests PROPERTIES LABELS lib.shell)

  # Not a test: prints what lexing typical lines costs. Use a Release build.
  add_executable(telar-shell-bench tests/syntax_bench.cpp)
  target_link_libraries(telar-shell-bench PRIVATE telar::shell)
endif()
