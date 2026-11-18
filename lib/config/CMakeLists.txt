telar_add_library(telar-config
  SOURCES client/client.cpp core/core.cpp gui/gui.cpp runtime/runtime.cpp runtime/runtime_reader.cpp snapshot/snapshot.cpp
  INCLUDES "${CMAKE_CURRENT_SOURCE_DIR}/include"
  DEPS telar::ghostty telar::lua telar::plugins)

if(BUILD_TESTING)
  # The runtime reader measures icon widths with libghostty-vt, which each program links itself.
  telar_add_tests(telar-config-tests LABEL lib.config LINK telar::config deps::ghostty_vt)
endif()
