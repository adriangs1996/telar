telar_add_domain(runtime core
  EXCLUDE model persistence
  SOURCES
    client_control/client_control.cpp
    delivery/client_delivery/client_delivery.cpp
    execution_service/execution_service-execution.cpp
    execution_service/execution_service.cpp
    media_service/media_service.cpp
    runtime/runtime.cpp
    runtime_telemetry/runtime_telemetry.cpp
  DEPS diagnostics transport suggestions host workers paths files terminal/shell_integration terminal/shell_completion workspaces workspaces/worktrees
       metrics terminal history terminal/graphics agents traffic/tap agents/observation core/model traffic/exchange_capture
       traffic/proxy plugins workspaces/editors core/persistence nvim)

if(BUILD_TESTING)
  # A case that drives a runtime host ends within the timeout even if a process it started hangs.
  telar_add_domain_tests(core TIMEOUT 300 LINK telar::base telar::client telar::config telar::git telar::lua telar::msgpack telar::platform telar::render telar::vocabulary telar::wire ebnf::ebnf)
  # The native clipboard tests reach the system pasteboard through the GUI tests' private one.
  if(APPLE AND TELAR_CLIPBOARD_NATIVE)
    target_sources(runtime-core-tests PRIVATE tests/runtime_clipboard_native.cpp
      "${TELAR_PROCESS_SOURCE_DIR}/../gui/tests/platform/macos/private_clipboard.mm")
    target_include_directories(runtime-core-tests PRIVATE "${TELAR_PROCESS_SOURCE_DIR}/../gui/tests")
    set_target_properties(runtime-core-tests PROPERTIES OBJCXX_STANDARD 23 OBJCXX_STANDARD_REQUIRED YES)
    target_compile_options(runtime-core-tests PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
    target_compile_definitions(runtime-core-tests PRIVATE TELAR_TEST_NATIVE_CLIPBOARD=1)
  endif()
endif()
