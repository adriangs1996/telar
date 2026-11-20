telar_add_domain(runtime workspaces/editors
  SOURCES
    remote_editor/remote_editor.cpp
  DEPS transport host workers)

if(BUILD_TESTING)
  telar_add_domain_tests(workspaces/editors LINK telar::base telar::config telar::platform telar::wire)
endif()
