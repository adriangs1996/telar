# The harness of every test program in lib/ and src/: cases, child modes, checks and the
# fixtures tests of several folders share. Built only with tests and never installed. Like a
# test, the quality checks leave it out.
telar_add_library(telar-testing
  SOURCES testing.cpp
  DEPS telar::tbc telar::sys telar::base telar::platform
  CHECKS)

# The main CTest drives: it runs the cases telar::testing registered. A program that needs a
# process-wide object before its cases, as the GUI's QGuiApplication, links its own main.
add_library(telar-testing-main STATIC main.cpp)
add_library(telar::testing-main ALIAS telar-testing-main)
target_link_libraries(telar-testing-main PUBLIC telar::testing)

if(BUILD_TESTING)
  telar_add_tests(telar-testing-tests LABEL lib.testing)
endif()
