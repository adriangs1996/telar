telar_add_domain(runtime model
  SOURCES
    client_layouts/client_layouts-launch_record.cpp
    client_layouts/client_layouts.cpp
    slot_store/slot_store.cpp
  DEPS diagnostics transport platform shell_integration terminal command_capture graphics agents
       observation)
