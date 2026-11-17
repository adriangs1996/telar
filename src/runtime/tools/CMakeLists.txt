# Probes run by hand or by the scripts of this folder, never by CTest: building them on every
# test run costs a full module compile each. `cmake --build out --target runtime-probes` builds
# them. runtime-tools-support holds the protocol peer and the fixtures they share.
telar_process_settings(runtime_settings)
telar_add_test(runtime-tools-support STATIC
  SOURCES protocol_peer/protocol_peer.cppm agent_oracle/agent_oracle.cppm control_png_pty_inputs/control_png_pty_inputs.cppm
  LIBRARIES ${runtime_settings} telar::base telar::client telar::platform telar::vocabulary telar::wire telar::testing)
target_compile_options(runtime-tools-support PUBLIC ${TELAR_PROCESS_OPTIONS})

telar_add_test(plugin-exchange-probe PROBE SOURCES plugin_exchange_probe.cpp LIBRARIES runtime-vocabulary runtime-plugins runtime-tools-support)
telar_add_test(proxy-probe PROBE SOURCES proxy_probe.cpp LIBRARIES runtime-proxy runtime-tools-support)
telar_add_test(control-pty-latency-probe PROBE SOURCES control_pty_latency_probe.cpp LIBRARIES runtime-tools-support)
telar_add_test(control-clipboard-lifetime-probe PROBE SOURCES control_clipboard_lifetime_probe.cpp LIBRARIES runtime-runtime-tests-support runtime-tools-support)
telar_add_test(control-query-probe SHARED
  SOURCES control_query_probe.cpp control_component_probe.cpp control_clipboard_fixture/control_clipboard_fixture.cppm
  LIBRARIES runtime-diagnostics runtime-terminal runtime-runtime-tests-support runtime-tools-support)
telar_add_test(terminal-media-feed-probe PROBE SOURCES terminal_media_feed_probe.cpp LIBRARIES runtime-terminal runtime-graphics)
telar_add_test(command-capture-probe PROBE SOURCES command_capture_probe.cpp LIBRARIES runtime-shell_integration runtime-terminal runtime-history runtime-command_capture runtime-graphics)
telar_add_test(control-query-accounting-probe PROBE SOURCES control_accounting_probe.cpp LIBRARIES runtime-terminal runtime-tools-support)
telar_add_test(launch-probe PROBE SOURCES launch_probe.cpp LIBRARIES runtime-tools-support)
telar_add_test(path-probe PROBE SOURCES path_probe.cpp LIBRARIES runtime-tools-support)
telar_add_test(reporter-probe PROBE SOURCES reporter_probe.cpp LIBRARIES runtime-tools-support)
telar_add_test(description-probe PROBE SOURCES description_probe.cpp LIBRARIES runtime-history runtime-tools-support)
telar_add_test(session-file-probe PROBE SOURCES session_file_probe.cpp LIBRARIES runtime-history runtime-tools-support)
telar_add_test(shell-capture-probe PROBE SOURCES shell_capture_probe.cpp LIBRARIES runtime-tools-support)
telar_add_test(runtime-probe PROBE SOURCES runtime_probe.cpp LIBRARIES runtime-terminal runtime-tools-support)
telar_add_test(graphics-probe PROBE SOURCES graphics_probe.cpp LIBRARIES runtime-tools-support)
telar_add_test(services-probe PROBE SOURCES services_probe.cpp LIBRARIES runtime-tools-support)
# server-cli-tests drives the runtime through it.
telar_add_test(checkpoint-probe NO_TEST SOURCES checkpoint_probe.cpp LIBRARIES runtime-tools-support)
# A fixture of its own virtual interface; CTest runs its packet self-test.
telar_add_test(traffic-interface-probe SOURCES traffic_interface_probe.cpp LIBRARIES runtime-platform runtime-traffic runtime-tools-support
  TEST traffic-interface-fixture-tests ARGS --self-test LABELS runtime.traffic)
telar_add_probes(runtime-probes)
