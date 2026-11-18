telar_add_library(telar-shell SOURCES syntax/syntax.cpp)

if(BUILD_TESTING)
  telar_add_tests(telar-shell-tests LABEL lib.shell LINK telar::shell)
  target_compile_options(telar-shell-tests PRIVATE ${TELAR_WARNINGS})

  # Not a test: prints what lexing typical lines costs. Use a Release build.
  add_executable(telar-shell-bench tools/syntax_bench.cpp)
  target_link_libraries(telar-shell-bench PRIVATE telar::shell)
endif()
