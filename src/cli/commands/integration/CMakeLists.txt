telar_add_domain(cli commands/integration
  SOURCES
    settings/integration.cpp
    settings/settings.cpp
  DEPS console/command_error)

if(BUILD_TESTING)
  telar_add_domain_tests(commands/integration LINK telar::base)

  # The Neovim plugin `integration install neovim` writes, run in a Neovim of its own when the
  # machine has one.
  find_program(TELAR_NVIM nvim)
  if(TELAR_NVIM)
    foreach(neovim_case IN ITEMS theme navigate)
      add_test(NAME cli.commands.integration.neovim.${neovim_case}
        COMMAND "${TELAR_NVIM}" --headless --clean -l "${CMAKE_CURRENT_SOURCE_DIR}/../../../../integrations/nvim/tests/${neovim_case}_test.lua")
      set_tests_properties(cli.commands.integration.neovim.${neovim_case} PROPERTIES LABELS cli.commands.integration TIMEOUT 30)
    endforeach()
  endif()
endif()
