telar_add_library(telar-plugins
  SOURCES plugins.cpp
  DEPS telar::platform telar::client)

if(BUILD_TESTING)
  telar_add_tests(telar-plugins-tests LABEL lib.plugins LINK telar::plugins)
endif()
