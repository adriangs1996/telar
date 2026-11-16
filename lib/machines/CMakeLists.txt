telar_add_library(telar-machines
  SOURCES machines.cpp
  INCLUDES "${CMAKE_CURRENT_SOURCE_DIR}/include"
  DEPS telar::client)
