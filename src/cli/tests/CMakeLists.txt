# The test programs and probes of the CLI. A shared check module serves the C++ tests;
# the Python tests drive the telar executable, and the ones that need a runtime run only
# where the runtime builds beside the CLI.
telar_add_test(cli-test-check STATIC SOURCES check/check.cppm LIBRARIES telar::build_flags)

telar_add_test(hook-tests SOURCES hooks_test.cpp LIBRARIES cli-hooks cli-hook cli-test-check
  LABELS cli.hooks)
telar_add_test(integration-tests SOURCES integration_test.cpp LIBRARIES cli-integration cli-tab cli-test-check
  LABELS cli.integration)
telar_add_test(json-text-tests SOURCES json_text_test.cpp LIBRARIES cli-output cli-test-check
  LABELS cli.output)
telar_add_test(arguments-tests SOURCES arguments_test.cpp LIBRARIES cli-command_limit cli-test-check
  LABELS cli.command_limit)
telar_add_test(hook-mapping-probe NO_TEST SOURCES hook_mapping_probe.cpp LIBRARIES cli-hooks cli-hook)
telar_add_test(repository-prepare-probe NO_TEST SOURCES repository_prepare_probe.cpp LIBRARIES cli-command_limit cli-worktree_git cli-worktree)

telar_add_test(cli-help-tests COMMAND Python3::Interpreter -B "${CMAKE_CURRENT_SOURCE_DIR}/help_test.py"
  --telar "$<TARGET_FILE:telar>" --help-directory "${TELAR_PROCESS_SOURCE_DIR}/help" --version "${TELAR_VERSION}"
  LABELS cli.base)
telar_add_test(cli-session-arguments-tests COMMAND Python3::Interpreter -B "${TELAR_PROCESS_SOURCE_DIR}/tools/check_sessions_cli.py"
  --cpp "$<TARGET_FILE:telar>" --validation-only
  LABELS cli.tab)
if(TARGET telar-runtime)
  telar_add_test(cli-sessions-tests COMMAND Python3::Interpreter -B "${TELAR_PROCESS_SOURCE_DIR}/tools/check_sessions_cli.py"
    --cpp "$<TARGET_FILE:telar>"
    LABELS cli.tab TIMEOUT 120)
endif()
telar_add_test(clipboard-cli-tests COMMAND Python3::Interpreter -B "${CMAKE_CURRENT_SOURCE_DIR}/clipboard_test.py"
  --telar "$<TARGET_FILE:telar>"
  LABELS cli.runtime_observer TIMEOUT 30)
telar_add_test(pane-agent-cli-tests COMMAND Python3::Interpreter -B "${CMAKE_CURRENT_SOURCE_DIR}/pane_agent_test.py"
  --telar "$<TARGET_FILE:telar>"
  LABELS cli.project_setup)
# Expected outputs were recorded on macOS: the window launch checks the
# display first on Linux, and setup reports the local platform.
if(APPLE)
  telar_add_test(machines-launch-cli-tests COMMAND Python3::Interpreter -B "${CMAKE_CURRENT_SOURCE_DIR}/machines_launch_test.py"
    --telar "$<TARGET_FILE:telar>"
    LABELS cli.machine TIMEOUT 90)
  telar_add_test(machine-setup-cli-tests COMMAND Python3::Interpreter -B "${CMAKE_CURRENT_SOURCE_DIR}/machine_setup_test.py"
    --telar "$<TARGET_FILE:telar>"
    LABELS cli.machine TIMEOUT 120)
endif()
telar_add_test(exec-runtime-offline-tests COMMAND Python3::Interpreter -B "${CMAKE_CURRENT_SOURCE_DIR}/exec_runtime_test.py"
  --telar "$<TARGET_FILE:telar>" --offline
  LABELS cli.worktree)
if(TARGET telar-runtime)
  telar_add_test(exec-runtime-cli-tests COMMAND Python3::Interpreter -B "${CMAKE_CURRENT_SOURCE_DIR}/exec_runtime_test.py"
    --telar "$<TARGET_FILE:telar>" --prepare-probe "$<TARGET_FILE:repository-prepare-probe>"
    LABELS cli.worktree TIMEOUT 90)
endif()
telar_add_test(cli-window-tests COMMAND Python3::Interpreter -B "${CMAKE_CURRENT_SOURCE_DIR}/window_test.py"
  --telar "$<TARGET_FILE:telar>"
  LABELS cli.window)
