include_guard(GLOBAL)

# Sets <out> to the tbc-lint a project uses: TBC_LINTER, then the project's .tbc.json, then PATH.
# Works in script mode too; <out> ends in -NOTFOUND when no linter is configured.
function(tbc_find_linter project_directory out)
  if(TBC_LINTER)
    set(command "${TBC_LINTER}")
  elseif(DEFINED ENV{TBC_LINTER} AND NOT "$ENV{TBC_LINTER}" STREQUAL "")
    set(command "$ENV{TBC_LINTER}")
  elseif(EXISTS "${project_directory}/.tbc.json")
    file(READ "${project_directory}/.tbc.json" configuration)
    string(JSON command ERROR_VARIABLE error GET "${configuration}" linter)
    if(error)
      message(FATAL_ERROR "Invalid linter in ${project_directory}/.tbc.json: ${error}")
    endif()
    cmake_path(ABSOLUTE_PATH command BASE_DIRECTORY "${project_directory}" NORMALIZE)
  else()
    find_program(command NAMES tbc-lint)
  endif()
  set(${out} "${command}" PARENT_SCOPE)
endfunction()

# Sources must be translation units present in the consumer's compilation database.
function(tbc_add_lifetime_check target)
  set(TBC_LINTER "" CACHE FILEPATH "Path to tbc-lint; otherwise use the project .tbc.json or PATH")
  set(dependencies)
  if(TARGET tbc-lint)
    set(command "$<TARGET_FILE:tbc-lint>")
    list(APPEND dependencies tbc-lint)
  else()
    tbc_find_linter("${CMAKE_CURRENT_SOURCE_DIR}" command)
    if(NOT command)
      message(FATAL_ERROR "tbc-lint was not found; set TBC_LINTER or add a .tbc.json")
    endif()
  endif()

  add_custom_target(${target}
    COMMAND "${command}" --warnings-as-errors "-p=${CMAKE_CURRENT_BINARY_DIR}" ${ARGN}
    DEPENDS ${dependencies}
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    USES_TERMINAL
    VERBATIM)
endfunction()
