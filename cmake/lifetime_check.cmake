include_guard(GLOBAL)

include("${CMAKE_CURRENT_LIST_DIR}/lint_prepare.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/../lib/tbc/cmake/tbcLifetimeCheck.cmake")

# Builds what the selected translation units read, then checks their lifetimes
# with the project's tbc-lint, <jobs> units at a time.
function(telar_lifetime_check project_directory build_directory include_regex exclude_regex jobs)
  tbc_find_linter("${project_directory}" linter)
  if(NOT EXISTS "${linter}")
    message(FATAL_ERROR "tbc-lint was not found at '${linter}'. Build lib/tbc with its release preset or set TBC_LINTER.")
  endif()
  telar_lint_prepare("${build_directory}" "${include_regex}" "${exclude_regex}" "${jobs}" patterns sources)
  execute_process(COMMAND "${linter}" --warnings-as-errors "-p=${build_directory}" "-j=${jobs}" ${sources}
    WORKING_DIRECTORY "${project_directory}"
    COMMAND_ERROR_IS_FATAL ANY)
endfunction()

# Sets <out> to JOBS when the script was given it, otherwise to the physical core count.
function(telar_lifetime_jobs out)
  if(DEFINED JOBS)
    set(jobs "${JOBS}")
  else()
    cmake_host_system_information(RESULT jobs QUERY NUMBER_OF_PHYSICAL_CORES)
  endif()
  if(NOT jobs MATCHES "^[1-9][0-9]*$")
    message(FATAL_ERROR "JOBS must be a positive integer")
  endif()
  set(${out} "${jobs}" PARENT_SCOPE)
endfunction()
