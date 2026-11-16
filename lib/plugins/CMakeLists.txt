telar_add_library(telar-plugins
  SOURCES plugins.cpp
  INCLUDES "${CMAKE_CURRENT_SOURCE_DIR}/include"
  DEPS telar::platform telar::client)
