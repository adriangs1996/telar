include_guard(GLOBAL)

# Sources must be translation units present in the consumer's compilation database.
function(tbc_add_lifetime_check target)
  set(TBC_LINTER "" CACHE FILEPATH "Path to tbc-lint; otherwise use the project .tbc.json or PATH")
  set(dependencies)
  if(TARGET tbc-lint)
    set(command "$<TARGET_FILE:tbc-lint>")
    list(APPEND dependencies tbc-lint)
  elseif(TBC_LINTER)
    set(command "${TBC_LINTER}")
  elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/.tbc.json")
    file(READ "${CMAKE_CURRENT_SOURCE_DIR}/.tbc.json" configuration)
    string(JSON command ERROR_VARIABLE error GET "${configuration}" linter)
    if(error)
      message(FATAL_ERROR "Invalid linter in .tbc.json: ${error}")
    endif()
    cmake_path(ABSOLUTE_PATH command BASE_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}" NORMALIZE)
  else()
    find_program(command NAMES tbc-lint REQUIRED)
  endif()

  add_custom_target(${target}
    COMMAND "${command}" --warnings-as-errors "-p=${CMAKE_CURRENT_BINARY_DIR}" ${ARGN}
    DEPENDS ${dependencies}
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    USES_TERMINAL
    VERBATIM)
endfunction()
