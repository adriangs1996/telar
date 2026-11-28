# History import reads the databases of other history tools with the SQLite the runtime uses,
# so this domain links it, and the CLI with it, on its own.
telar_add_domain(cli commands/history
  SOURCES
    history.cpp
    sources/database.cpp
    sources/sources.cpp
    output/output.cpp
  DEPS console/command_limit session/control_session session/runtime_observer session/server telar::native deps::sqlite3)

if(BUILD_TESTING)
  telar_add_domain_tests(commands/history LINK telar::base)
  # What `telar history` prints for fixture files of every source, against a private runtime.
  if(TARGET telar-runtime)
    telar_add_test(cli-commands-history-cli-tests COMMAND Python3::Interpreter -B "${CMAKE_CURRENT_SOURCE_DIR}/tests/history_cli_test.py"
      --telar "$<TARGET_FILE:telar>"
      LABELS cli.commands.history TIMEOUT 300)
  endif()
endif()
