# Shared test fixtures are module interfaces. Test programs link them beside
# runtime-core, which the fixtures themselves import.
file(GLOB runtime_test_fixtures CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/*/*.cppm")
telar_add_test(runtime-test-fixtures STATIC SOURCES ${runtime_test_fixtures} LIBRARIES runtime-core)

telar_add_test(event-loop-tests SOURCES event_loop_test.cpp LIBRARIES runtime-core runtime-test-fixtures
  LABELS runtime.platform TIMEOUT 10)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  telar_add_test(linux-platform-tests SOURCES linux_platform_test.cpp LIBRARIES runtime-core runtime-test-fixtures
    LABELS runtime.platform TIMEOUT 15)
endif()

telar_add_test(hook-probe PROBE SOURCES hook_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(diagnostics-tests SOURCES diagnostics_test.cpp LIBRARIES runtime-core runtime-test-fixtures
  LABELS runtime.diagnostics)
# telar.ghostty.vt packs its mode constants itself; this checks each against libghostty-vt's.
telar_add_test(ghostty-modes-tests SOURCES ghostty_modes_test.cpp LIBRARIES telar::ghostty
  LABELS runtime.terminal)
telar_add_test(plugin-package-probe PROBE SOURCES plugin_package_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(plugin-exchange-probe PROBE SOURCES plugin_exchange_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(plugin-service-probe PROBE SOURCES plugin_service_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(proxy-probe PROBE SOURCES proxy_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(service-admission-probe PROBE SOURCES service_admission_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(admission-probe PROBE SOURCES admission_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(input-capacity-probe PROBE SOURCES input_capacity_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(deferred-response-probe PROBE SOURCES deferred_response_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
# Keep launch and macOS process-inspection names identical before the first refresh.
set_target_properties(deferred-response-probe PROPERTIES OUTPUT_NAME deferred-probe)
telar_add_test(control-pty-latency-probe PROBE SOURCES control_pty_latency_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(control-clipboard-lifetime-probe PROBE SOURCES control_clipboard_lifetime_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(control-query-probe SHARED SOURCES control_query_probe.cpp control_component_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(terminal-media-feed-probe PROBE SOURCES terminal_media_feed_probe.cpp LIBRARIES runtime-core)
telar_add_test(command-capture-probe PROBE SOURCES command_capture_probe.cpp LIBRARIES runtime-core)
telar_add_test(control-query-accounting-probe PROBE SOURCES control_accounting_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(control-queue-tests SOURCES control_queue_test.cpp pty_response_queue_test.cpp LIBRARIES runtime-core runtime-test-fixtures
  LABELS runtime.terminal TIMEOUT 15)
target_include_directories(control-queue-tests PRIVATE "${TELAR_PROCESS_SOURCE_DIR}")
target_compile_options(control-queue-tests PRIVATE -Wall -Wextra -Wpedantic)
# The parser and the ordinary scans run from runtime-core's control module. Each scan test calls
# both of its instruction sets: the target's vectors and the byte loop of a target without them.
foreach(control_target IN ITEMS control-parser control-osc-owned control-scanner control-ascii)
  string(REPLACE "-" "_" control_source "${control_target}")
  telar_add_test(${control_target}-tests SOURCES ${control_source}_test.cpp LIBRARIES runtime-core
    LABELS runtime.terminal)
  target_compile_options(${control_target}-tests PRIVATE -Wall -Wextra -Wpedantic)
endforeach()
telar_add_test(control-engine-tests SOURCES control_engine_test.cpp pty_response_queue_test.cpp LIBRARIES runtime-core runtime-test-fixtures
  LABELS runtime.terminal)
telar_add_test(control-kitty-colors-tests SOURCES control_kitty_colors_test.cpp LIBRARIES runtime-core runtime-test-fixtures
  LABELS runtime.terminal)
telar_add_test(runtime-clipboard-tests SOURCES runtime_clipboard_test.cpp LIBRARIES runtime-core runtime-test-fixtures
  LABELS runtime.runtime TIMEOUT 15)
if(APPLE AND TELAR_CLIPBOARD_NATIVE)
  target_sources(runtime-clipboard-tests PRIVATE runtime_clipboard_native_test.cpp
    "${TELAR_PROCESS_SOURCE_DIR}/../gui/tests/platform/macos/private_clipboard.mm")
  target_include_directories(runtime-clipboard-tests PRIVATE "${TELAR_PROCESS_SOURCE_DIR}/../gui/tests")
  set_target_properties(runtime-clipboard-tests PROPERTIES OBJCXX_STANDARD 23 OBJCXX_STANDARD_REQUIRED YES)
  target_compile_options(runtime-clipboard-tests PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
  target_compile_definitions(runtime-clipboard-tests PRIVATE TELAR_TEST_NATIVE_CLIPBOARD=1)
endif()
option(TELAR_CLIPBOARD_INTEGRATION_TESTS "Test native clipboard on a private headless Wayland session" OFF)
if(TELAR_CLIPBOARD_NATIVE AND TELAR_CLIPBOARD_INTEGRATION_TESTS AND CMAKE_SYSTEM_NAME STREQUAL "Linux")
  foreach(program IN ITEMS sway wl-copy wl-paste)
    find_program(clipboard_test_${program} ${program} REQUIRED)
  endforeach()
  telar_add_test(runtime-clipboard-native-tests COMMAND Python3::Interpreter -B
    "${TELAR_PROCESS_SOURCE_DIR}/tools/check_runtime_clipboard.py" --telar "$<TARGET_FILE:telar>"
    LABELS runtime.runtime TIMEOUT 60)
endif()
telar_add_test(control-clipboard-tests SOURCES control_clipboard_test.cpp LIBRARIES runtime-core runtime-test-fixtures
  LABELS runtime.terminal)
telar_add_test(control-graphics-tests SOURCES control_graphics_test.cpp LIBRARIES runtime-core runtime-test-fixtures
  LABELS runtime.terminal TIMEOUT 15)
telar_add_test(control-desktop-tests SOURCES control_desktop_test.cpp LIBRARIES runtime-core runtime-test-fixtures
  LABELS runtime.terminal)
telar_add_test(worktree-lifecycle-probe PROBE SOURCES worktree_lifecycle_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(launch-probe PROBE SOURCES launch_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(worktree-detection-probe PROBE SOURCES worktree_detection_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(workspace-git-probe PROBE SOURCES workspace_git_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(path-probe PROBE SOURCES path_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(reporter-probe PROBE SOURCES reporter_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(process-probe PROBE SOURCES process_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(description-probe PROBE SOURCES description_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(session-file-probe PROBE SOURCES session_file_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(capture-probe PROBE SOURCES capture_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(shell-capture-probe PROBE SOURCES shell_capture_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(screen-probe PROBE SOURCES screen_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(model-probe PROBE SOURCES model_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(checkpoint-probe NO_TEST SOURCES checkpoint_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(server-cli-tests COMMAND Python3::Interpreter -B "${CMAKE_CURRENT_SOURCE_DIR}/server_cli_test.py" --telar "$<TARGET_FILE:telar>" --checkpoint-probe "$<TARGET_FILE:checkpoint-probe>"
  LABELS runtime.cli TIMEOUT 90)
telar_add_test(resume-probe PROBE SOURCES resume_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(agent-probe PROBE SOURCES agent_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(runtime-probe PROBE SOURCES runtime_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(graphics-probe PROBE SOURCES graphics_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(graphics-limits-probe PROBE SOURCES graphics_limits_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(services-probe PROBE SOURCES services_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(history-probe PROBE SOURCES history_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(runtime-tests
  SOURCES
    main.cpp memory_test.cpp terminal_test.cpp frame_sync_test.cpp platform_test.cpp text_test.cpp client_control_test.cpp history_test.cpp control_services_test.cpp graphics_test.cpp background_services_test.cpp agents_test.cpp worktree_probe_test.cpp
    history_queue_test.cpp history_capacity_test.cpp path_service_test.cpp workspace_git_test.cpp worktree_detection_test.cpp
    input_capacity_test.cpp outgoing_frames_test.cpp deferred_responses_test.cpp client_delivery_test.cpp
    tab_holds_test.cpp
    pty_response_test.cpp pty_response_queue_test.cpp
    persistence_test.cpp observation_test.cpp command_capture_test.cpp shell_integration_test.cpp metrics_test.cpp cli_test.cpp lua_test.cpp config_test.cpp
    session_file_test.cpp description_test.cpp process_identification_test.cpp deferred_reports_test.cpp descent_test.cpp
    launch_directory_test.cpp launch_failure_test.cpp worktree_lifecycle_test.cpp admission_test.cpp media_test.cpp
    graphics_limits_test.cpp atomic_graphics_test.cpp atomic_runtime_test.cpp proxy_policy_test.cpp http1_test.cpp http2_test.cpp
    exchange_capture_test.cpp capture_decode_test.cpp transport_capture_test.cpp proxy_authentication_test.cpp proxy_network_test.cpp
    proxy_resolution_test.cpp proxy_transport_test.cpp
  LIBRARIES runtime-core runtime-test-fixtures
  LABELS runtime.runtime)
telar_add_test(tab-holds-probe PROBE SOURCES tab_holds_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
telar_add_test(tls-tests SOURCES tls_test.cpp tls_alpn_test.cpp tls_trust_test.cpp tls_session_test.cpp proxy_service_test.cpp proxy_trust_test.cpp
  LIBRARIES runtime-core runtime-test-fixtures
  LABELS runtime.tls)
telar_add_test(plugin-tests SOURCES plugin_test.cpp plugin_host_test.cpp plugin_channel_test.cpp plugin_package_test.cpp plugin_session_test.cpp plugin_service_test.cpp recycling_allocator_test.cpp
  LIBRARIES runtime-core runtime-test-fixtures
  LABELS runtime.plugins)
telar_add_test(traffic-tests SOURCES traffic_test.cpp LIBRARIES runtime-core runtime-test-fixtures
  LABELS runtime.traffic)
telar_add_test(traffic-interface-probe SOURCES traffic_interface_probe.cpp LIBRARIES runtime-core runtime-test-fixtures
  TEST traffic-interface-fixture-tests ARGS --self-test LABELS runtime.traffic)
if(APPLE)
  telar_add_test(redirect-tests SOURCES redirect_test.cpp LIBRARIES runtime-core runtime-test-fixtures
    LABELS runtime.redirect)
  telar_add_test(redirect-check-tests COMMAND Python3::Interpreter -B "${CMAKE_CURRENT_SOURCE_DIR}/redirect_check_test.py"
    LABELS runtime.redirect)
endif()
telar_add_test(network-check-tests COMMAND Python3::Interpreter -B "${CMAKE_CURRENT_SOURCE_DIR}/network_check_test.py" --runtime "$<TARGET_FILE:telar-runtime>"
  LABELS runtime.traffic)
telar_add_test(browser-check-tests COMMAND Python3::Interpreter -B "${CMAKE_CURRENT_SOURCE_DIR}/browser_check_test.py"
  LABELS runtime.tls)
telar_add_test(state-delivery-probe PROBE SOURCES state_delivery_probe.cpp LIBRARIES runtime-core runtime-test-fixtures)
set_target_properties(state-delivery-probe PROPERTIES OUTPUT_NAME state-probe)

telar_add_test(traffic-flow-tests SOURCES traffic_flow_test.cpp http1_test.cpp http2_test.cpp proxy_transport_test.cpp transport_capture_test.cpp
  LIBRARIES runtime-core runtime-test-fixtures
  LABELS runtime.traffic)

telar_add_test(http-message-tests SOURCES http_message_test.cpp http_interception_test.cpp LIBRARIES runtime-core runtime-test-fixtures
  LABELS runtime.http)

telar_add_test(http2-endpoint-tests SOURCES http2_endpoint_test.cpp LIBRARIES runtime-core runtime-test-fixtures
  LABELS runtime.http2)
telar_add_test(traffic-control-tests SOURCES traffic_control_test.cpp LIBRARIES runtime-core runtime-test-fixtures
  LABELS runtime.traffic)
telar_add_test(plugin-traffic-tests SOURCES plugin_traffic_test.cpp LIBRARIES runtime-core runtime-test-fixtures
  LABELS runtime.plugins)
telar_add_test(traffic-recording-tests SOURCES traffic_recording_test.cpp LIBRARIES runtime-core runtime-test-fixtures
  LABELS runtime.traffic)
if(APPLE)
  telar_add_test(socket-owner-tests SOURCES socket_owner_test.cpp LIBRARIES runtime-core runtime-test-fixtures
    LABELS runtime.redirect)
endif()
telar_add_test(redirect-selection-tests SOURCES redirect_selection_test.cpp LIBRARIES runtime-core runtime-test-fixtures
  LABELS runtime.redirect)
telar_add_test(ip-fragment-tests SOURCES ip_fragments_test.cpp LIBRARIES runtime-core runtime-test-fixtures
  LABELS runtime.traffic)
telar_add_test(datagram-tests SOURCES datagram_test.cpp LIBRARIES runtime-core runtime-test-fixtures
  LABELS runtime.traffic)

telar_add_test(plugin-action-worker COMMAND Python3::Interpreter "${TELAR_PROCESS_SOURCE_DIR}/tools/compare_action_workers.py" --cpp "$<TARGET_FILE:telar-runtime>"
  LABELS runtime.plugins TIMEOUT 90)

# Probes run by hand or by tools/ scripts, never by CTest: building them on every test run
# costs a full module compile each. `cmake --build out --target runtime-probes` builds them.
telar_add_probes(runtime-probes)
