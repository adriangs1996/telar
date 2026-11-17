telar_add_library(telar-machines
  SOURCES machines.cpp
  INCLUDES "${CMAKE_CURRENT_SOURCE_DIR}/include"
  DEPS telar::client)

if(BUILD_TESTING)
  telar_add_tests(telar-machines-tests LABEL lib.machines LINK telar::machines)
endif()
