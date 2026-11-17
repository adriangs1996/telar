# The Python tests that drive the telar executable, labelled cli.e2e; the ones that need a
# runtime run only where the runtime builds beside the CLI. The tests of one domain live in its
# own tests/ folder, and a C++ test that reaches domains no single domain builds on goes here.
telar_add_test(repository-prepare-probe NO_TEST SOURCES ${TELAR_PROCESS_SOURCE_DIR}/tools/repository_prepare_probe.cpp
  LIBRARIES cli-command_limit cli-worktree_git cli-worktree)

telar_add_test(cli-help-tests COMMAND Python3::Interpreter -B "${CMAKE_CURRENT_SOURCE_DIR}/help_test.py"
  --telar "$<TARGET_FILE:telar>" --help-directory "${TELAR_PROCESS_SOURCE_DIR}/help" --version "${TELAR_VERSION}"
  LABELS cli.e2e)
telar_add_test(cli-session-arguments-tests COMMAND Python3::Interpreter -B "${TELAR_PROCESS_SOURCE_DIR}/tools/check_sessions_cli.py"
  --cpp "$<TARGET_FILE:telar>" --validation-only
  LABELS cli.e2e)
if(TARGET telar-runtime)
  telar_add_test(cli-sessions-tests COMMAND Python3::Interpreter -B "${TELAR_PROCESS_SOURCE_DIR}/tools/check_sessions_cli.py"
    --cpp "$<TARGET_FILE:telar>"
    LABELS cli.e2e TIMEOUT 120)
endif()
telar_add_test(clipboard-cli-tests COMMAND Python3::Interpreter -B "${CMAKE_CURRENT_SOURCE_DIR}/clipboard_test.py"
  --telar "$<TARGET_FILE:telar>"
  LABELS cli.e2e TIMEOUT 30)
telar_add_test(pane-agent-cli-tests COMMAND Python3::Interpreter -B "${CMAKE_CURRENT_SOURCE_DIR}/pane_agent_test.py"
  --telar "$<TARGET_FILE:telar>"
  LABELS cli.e2e)
telar_add_test(hook-cli-tests COMMAND Python3::Interpreter -B "${CMAKE_CURRENT_SOURCE_DIR}/hook_cli_test.py"
  --telar "$<TARGET_FILE:telar>"
  LABELS cli.e2e TIMEOUT 90)
telar_add_test(hook-worktree-cli-tests COMMAND Python3::Interpreter -B "${CMAKE_CURRENT_SOURCE_DIR}/hook_worktree_test.py"
  --telar "$<TARGET_FILE:telar>"
  LABELS cli.e2e TIMEOUT 90)
# Expected outputs were recorded on macOS: the window launch checks the
# display first on Linux, and setup reports the local platform.
if(APPLE)
  telar_add_test(machines-launch-cli-tests COMMAND Python3::Interpreter -B "${CMAKE_CURRENT_SOURCE_DIR}/machines_launch_test.py"
    --telar "$<TARGET_FILE:telar>"
    LABELS cli.e2e TIMEOUT 90)
  telar_add_test(machine-setup-cli-tests COMMAND Python3::Interpreter -B "${CMAKE_CURRENT_SOURCE_DIR}/machine_setup_test.py"
    --telar "$<TARGET_FILE:telar>"
    LABELS cli.e2e TIMEOUT 120)
endif()
telar_add_test(exec-runtime-offline-tests COMMAND Python3::Interpreter -B "${CMAKE_CURRENT_SOURCE_DIR}/exec_runtime_test.py"
  --telar "$<TARGET_FILE:telar>" --offline
  LABELS cli.e2e)
if(TARGET telar-runtime)
  telar_add_test(exec-runtime-cli-tests COMMAND Python3::Interpreter -B "${CMAKE_CURRENT_SOURCE_DIR}/exec_runtime_test.py"
    --telar "$<TARGET_FILE:telar>" --prepare-probe "$<TARGET_FILE:repository-prepare-probe>"
    LABELS cli.e2e TIMEOUT 90)
endif()
telar_add_test(integration-cli-tests COMMAND Python3::Interpreter -B "${CMAKE_CURRENT_SOURCE_DIR}/integration_cli_test.py"
  --telar "$<TARGET_FILE:telar>"
  LABELS cli.e2e TIMEOUT 60)
telar_add_test(render-cli-tests COMMAND Python3::Interpreter -B "${CMAKE_CURRENT_SOURCE_DIR}/render_test.py"
  --telar "$<TARGET_FILE:telar>"
  LABELS cli.e2e TIMEOUT 30)
telar_add_test(cli-window-tests COMMAND Python3::Interpreter -B "${CMAKE_CURRENT_SOURCE_DIR}/window_test.py"
  --telar "$<TARGET_FILE:telar>"
  LABELS cli.e2e)
