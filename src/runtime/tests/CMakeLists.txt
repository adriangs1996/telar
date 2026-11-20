# The integration tests of the runtime: each reaches domains that no single domain builds on.
# The tests of one domain live in its own tests/ folder (tools/check-cpp-modules.py, rule 9).
telar_add_tests(runtime-tests LABEL runtime.integration DIRECTORY .
  LINK runtime-editors runtime-paths runtime-platform runtime-suggestions runtime-transport runtime-traffic
    runtime-traffic-exchange_capture runtime-traffic-tap runtime-workspaces runtime-worktrees
    telar::base telar::config telar::platform telar::vocabulary telar::wire)

# End-to-end checks of the built programs, labelled runtime.e2e.
option(TELAR_CLIPBOARD_INTEGRATION_TESTS "Test native clipboard on a private headless Wayland session" OFF)
if(TELAR_CLIPBOARD_NATIVE AND TELAR_CLIPBOARD_INTEGRATION_TESTS AND CMAKE_SYSTEM_NAME STREQUAL "Linux")
  foreach(program IN ITEMS sway wl-copy wl-paste)
    find_program(clipboard_test_${program} ${program} REQUIRED)
  endforeach()
  telar_add_test(runtime-clipboard-native-tests COMMAND Python3::Interpreter -B
    "${TELAR_PROCESS_SOURCE_DIR}/tools/check_runtime_clipboard.py" --telar "$<TARGET_FILE:telar>"
    LABELS runtime.e2e TIMEOUT 60)
endif()
telar_add_test(server-cli-tests COMMAND Python3::Interpreter -B "${CMAKE_CURRENT_SOURCE_DIR}/server_cli_test.py" --telar "$<TARGET_FILE:telar>" --checkpoint-probe "$<TARGET_FILE:checkpoint-probe>"
  LABELS runtime.e2e TIMEOUT 90)
if(APPLE)
  telar_add_test(redirect-check-tests COMMAND Python3::Interpreter -B "${CMAKE_CURRENT_SOURCE_DIR}/redirect_check_test.py"
    LABELS runtime.e2e)
  telar_add_test(redirect-arguments-tests COMMAND Python3::Interpreter -B "${CMAKE_CURRENT_SOURCE_DIR}/redirect_arguments_test.py" --runtime "$<TARGET_FILE:telar-runtime>"
    LABELS runtime.e2e TIMEOUT 60)
endif()
telar_add_test(plugin-action-worker COMMAND Python3::Interpreter "${TELAR_PROCESS_SOURCE_DIR}/tools/compare_action_workers.py" --cpp "$<TARGET_FILE:telar-runtime>"
  LABELS runtime.e2e TIMEOUT 90)
