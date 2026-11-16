telar_add_domain(runtime runtime
  SOURCES
    client_control/client_control.cpp
    delivery/client_delivery/client_delivery.cpp
    execution_service/execution_service-execution.cpp
    execution_service/execution_service.cpp
    media_service/media_service.cpp
    runtime/runtime.cpp
    runtime_telemetry/runtime_telemetry.cpp
  DEPS diagnostics transport suggestions platform paths shell_integration workspaces worktrees
       metrics terminal history graphics agents vocabulary observation model exchange_capture
       proxy plugins editors persistence)
