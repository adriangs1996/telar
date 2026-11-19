telar_add_domain(cli integration
  SOURCES
    settings/integration.cpp
    settings/settings.cpp
  DEPS base)

if(BUILD_TESTING)
  telar_add_domain_tests(integration LINK telar::base)

  # The Neovim plugin `integration install neovim` writes, run in a Neovim of its own when the
  # machine has one.
  find_program(TELAR_NVIM nvim)
  if(TELAR_NVIM)
    foreach(neovim_case IN ITEMS theme navigate)
      add_test(NAME cli.integration.neovim.${neovim_case}
        COMMAND "${TELAR_NVIM}" --headless --clean -l "${CMAKE_CURRENT_SOURCE_DIR}/../../../integrations/nvim/tests/${neovim_case}_test.lua")
      set_tests_properties(cli.integration.neovim.${neovim_case} PROPERTIES LABELS cli.integration TIMEOUT 30)
    endforeach()
  endif()
endif()
