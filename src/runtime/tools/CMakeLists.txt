# Probes run by hand or by the scripts of this folder, never by CTest: building them on every
# test run costs a full module compile each. `cmake --build out --target runtime-probes` builds
# them. runtime-tools-support holds the fixtures they share; the protocol peer comes from the
# runtime's test support, whose tests drive a runtime through it too.
telar_process_settings(runtime_settings)
telar_add_test(runtime-tools-support STATIC
  SOURCES control_png_pty_inputs/control_png_pty_inputs.cppm
  LIBRARIES ${runtime_settings} runtime-core-tests-support telar::base telar::client telar::platform telar::vocabulary telar::wire telar::testing)
target_compile_options(runtime-tools-support PUBLIC ${TELAR_PROCESS_OPTIONS})

telar_add_test(plugin-exchange-probe PROBE SOURCES plugin_exchange_probe.cpp LIBRARIES runtime-traffic-tap runtime-plugins runtime-tools-support)
telar_add_test(control-pty-latency-probe PROBE SOURCES control_pty_latency_probe.cpp LIBRARIES runtime-tools-support)
telar_add_test(control-query-probe SHARED
  SOURCES control_query_probe.cpp control_component_probe.cpp control_clipboard_fixture/control_clipboard_fixture.cppm
  LIBRARIES runtime-diagnostics runtime-terminal runtime-core-tests-support runtime-tools-support)
telar_add_test(runtime-probe PROBE SOURCES runtime_probe.cpp LIBRARIES runtime-terminal runtime-tools-support)
# server-cli-tests drives the runtime through it.
telar_add_test(checkpoint-probe NO_TEST SOURCES checkpoint_probe.cpp LIBRARIES runtime-tools-support)
# A fixture of its own virtual interface; CTest runs its packet self-test.
telar_add_test(traffic-interface-probe SOURCES traffic_interface_probe.cpp LIBRARIES runtime-host runtime-traffic runtime-tools-support
  TEST traffic-interface-fixture-tests ARGS --self-test LABELS runtime.traffic)
# Drives a real Neovim as the runtime's editor does and prints what it measured.
telar_add_test(nvim-embed-probe PROBE SOURCES nvim_embed_probe.cpp LIBRARIES runtime-nvim runtime-tools-support)
# What decoding a redraw and writing a client its frame cost, without a Neovim.
telar_add_test(nvim-redraw-bench PROBE SOURCES nvim_redraw_bench.cpp LIBRARIES runtime-nvim runtime-tools-support)
telar_add_probes(runtime-probes)
