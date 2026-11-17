# The harness of every test program in lib/ and src/ outside the GUI: cases, child modes,
# checks and the main CTest drives. Built only with tests and never installed.
telar_add_library(telar-testing
  SOURCES testing.cpp main.cpp
  DEPS telar::tbc telar::sys)
