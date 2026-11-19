telar_add_library(telar-machines
  SOURCES machines.cpp
  DEPS telar::client)

if(BUILD_TESTING)
  telar_add_tests(telar-machines-tests LABEL lib.machines LINK telar::machines)
endif()
