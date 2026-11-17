# The harness of every test program in lib/ and src/ outside the GUI: cases, child modes,
# checks and the main CTest drives, with the fixtures tests of several folders share.
# Built only with tests and never installed. Like a test, it keeps its function bodies in
# its interfaces, so it takes the checks of a test.
telar_add_library(telar-testing
  SOURCES testing.cpp main.cpp
  DEPS telar::tbc telar::sys telar::base telar::platform
  CHECKS lint blank_lines)
