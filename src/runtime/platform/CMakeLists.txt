telar_add_domain(runtime platform
  SOURCES
    background_executor/background_executor.cpp
    descriptor_path/descriptor_path.cpp
    git_status/git_status.cpp
    launch_program/launch_program.cpp
    local_listener/local_listener.cpp
    name_resolutions/name_resolutions.cpp
    private_tunnel/private_tunnel.cpp
    process_probe/process_inspector.cpp
    process_table/process_table.cpp
    request_worker/request_worker.cpp
    session_host/session_host.cpp
    signals/signals.cpp
    stream_read_buffer/stream_read_buffer.cpp
    system_certificates/system_certificates.cpp
  MACOS_SOURCES
    event_loop/macos/event_loop.cpp
    frameworks/frameworks.cppm
    host_metrics/macos/host_metrics.cpp
    process_probe/macos/process_inspector.cpp
    process_table/macos/process_table.cpp
  LINUX_SOURCES
    event_loop/linux/event_loop.cpp
    host_metrics/linux/host_metrics.cpp
    proc_file/proc_file.cpp
    proc_file/proc_file.cppm
    process_probe/linux/process_inspector.cpp
    process_table/linux/process_table.cpp
  DEPS diagnostics transport suggestions)

if(BUILD_TESTING)
  telar_add_domain_tests(platform LINK telar::base telar::client telar::git telar::platform telar::tls telar::wire telar-tls-tests-support)
endif()
