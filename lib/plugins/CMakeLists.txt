telar_add_library(telar-plugins
  SOURCES plugins.cpp
  INCLUDES "${CMAKE_CURRENT_SOURCE_DIR}/include"
  DEPS telar::platform telar::client)

if(BUILD_TESTING)
  telar_add_tests(telar-plugins-tests LABEL lib.plugins LINK telar::plugins)
endif()
