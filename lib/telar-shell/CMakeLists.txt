cmake_minimum_required(VERSION 4.4.5)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_shell LANGUAGES CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/cpp_modules.cmake")

add_library(telar-shell STATIC src/syntax.cpp)
add_library(telar::shell ALIAS telar-shell)
telar_modules(telar-shell)

telar_editor_flags(telar-shell)

if(PROJECT_IS_TOP_LEVEL)
  include(CTest)
  if(BUILD_TESTING)
    add_executable(telar-shell-tests tests/syntax_test.cpp)
    target_link_libraries(telar-shell-tests PRIVATE telar::shell)
    target_compile_options(telar-shell-tests PRIVATE -Wall -Wextra -Wpedantic)
    add_test(NAME telar-shell-tests COMMAND telar-shell-tests)

    # Not a test: prints what lexing typical lines costs. Use a Release build.
    add_executable(telar-shell-bench tests/syntax_bench.cpp)
    target_link_libraries(telar-shell-bench PRIVATE telar::shell)
  endif()
endif()
