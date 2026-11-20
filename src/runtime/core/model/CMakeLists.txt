telar_add_domain(runtime core/model
  SOURCES
    client_layouts/client_layouts-launch_record.cpp
    client_layouts/client_layouts.cpp
    slot_store/slot_store.cpp
  DEPS diagnostics transport host terminal/shell_integration terminal terminal/command_capture terminal/graphics agents
       agents/observation)

if(BUILD_TESTING)
  telar_add_domain_tests(core/model LINK telar::base telar::platform telar::wire)
endif()
