function(read_integration_asset output path)
  set(source "${CMAKE_CURRENT_SOURCE_DIR}/integration/assets/${path}")
  file(READ "${source}" contents)
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${source}")
  set(${output} "${contents}" PARENT_SCOPE)
endfunction()

read_integration_asset(TELAR_PI_INTEGRATION pi.ts)
read_integration_asset(TELAR_OPENCODE_INTEGRATION opencode.ts)
read_integration_asset(TELAR_AGENT_SKILL telar.md)
read_integration_asset(TELAR_COORDINATOR_SKILL coordinator.md)

# The Lua files of integrations/nvim that `telar integration install neovim` writes under
# Neovim's site directory, by their path there.
set(neovim_directory "${CMAKE_CURRENT_SOURCE_DIR}/../../integrations/nvim")
file(GLOB_RECURSE neovim_files RELATIVE "${neovim_directory}" CONFIGURE_DEPENDS
  "${neovim_directory}/plugin/*.lua" "${neovim_directory}/colors/*.lua" "${neovim_directory}/lua/*.lua")
list(SORT neovim_files)
set(TELAR_NEOVIM_FILES "")
foreach(neovim_file IN LISTS neovim_files)
  file(READ "${neovim_directory}/${neovim_file}" neovim_text)
  string(FIND "${neovim_text}" ")TelarAsset\"" delimiter_found)
  if(NOT delimiter_found EQUAL -1)
    message(FATAL_ERROR "${neovim_file} contains the raw string delimiter TelarAsset")
  endif()

  # configure_file would replace the text between two @ as a variable.
  string(REGEX MATCH "@[A-Za-z0-9_]+@" variable_found "${neovim_text}")
  if(variable_found)
    message(FATAL_ERROR "${neovim_file} contains ${variable_found}, which configure_file replaces")
  endif()

  string(APPEND TELAR_NEOVIM_FILES "    NeovimFile{.path = \"${neovim_file}\", .text = R\"TelarAsset(${neovim_text})TelarAsset\"},\n")
endforeach()

configure_file(integration/assets.inc.in "${CMAKE_CURRENT_BINARY_DIR}/generated/integration_assets.inc" @ONLY)
