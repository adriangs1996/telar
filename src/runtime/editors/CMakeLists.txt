telar_add_domain(runtime editors
  SOURCES
    remote_editor/remote_editor.cpp
  DEPS transport platform)

if(BUILD_TESTING)
  telar_add_domain_tests(editors LINK telar::base telar::config telar::platform telar::wire)
endif()
