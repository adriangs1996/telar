include_guard(GLOBAL)

# Build what every selected compile command reads before clang-tidy runs it:
# generated headers, module providers, dyndep/modmap files and the BMIs of
# CMake's synthetic module targets. clang-tidy analyses each database entry of
# a source, and an entry whose BMI is missing parses into an invalid AST that
# checks then walk. Sets <patterns> to run-clang-tidy file patterns and, when
# given, <sources> to the selected source paths.
function(telar_lint_prepare build_directory include_regex exclude_regex jobs patterns)
  # Let Ninja refresh CMake's database first, including after a new target or module.
  execute_process(COMMAND "${CMAKE_COMMAND}" --build "${build_directory}" --parallel "${jobs}" --target build.ninja
    COMMAND_ERROR_IS_FATAL ANY)
  file(READ "${build_directory}/compile_commands.json" commands)
  string(JSON count LENGTH "${commands}")
  set(objects)
  set(selected)
  set(paths)
  if(count GREATER 0)
    math(EXPR last "${count} - 1")
    foreach(index RANGE ${last})
      string(JSON source GET "${commands}" ${index} file)
      string(JSON directory GET "${commands}" ${index} directory)
      cmake_path(ABSOLUTE_PATH source BASE_DIRECTORY "${directory}" NORMALIZE)
      if(NOT source MATCHES "${include_regex}" OR source MATCHES "${exclude_regex}")
        continue()
      endif()
      string(JSON output ERROR_VARIABLE error GET "${commands}" ${index} output)
      if(error)
        message(FATAL_ERROR "No object output for ${source}; regenerate the database with the pinned Ninja toolchain")
      endif()
      cmake_path(ABSOLUTE_PATH output BASE_DIRECTORY "${directory}" NORMALIZE)
      file(RELATIVE_PATH object "${build_directory}" "${output}")
      if(object MATCHES "^\\.\\./" OR IS_ABSOLUTE "${object}")
        message(FATAL_ERROR "Object output outside the build directory: ${output}")
      endif()
      list(APPEND objects "${object}")
      list(APPEND paths "${source}")
      # run-clang-tidy treats positional filenames as Python regular expressions.
      string(REGEX REPLACE "([][+.*()?^$\\\\|])" "\\\\\\1" pattern "${source}")
      list(APPEND selected "^${pattern}$")
    endforeach()
  endif()
  list(REMOVE_DUPLICATES objects)
  list(REMOVE_DUPLICATES selected)
  list(REMOVE_DUPLICATES paths)
  if(NOT objects)
    message(FATAL_ERROR "No translation units in ${build_directory} match ${include_regex}")
  endif()
  execute_process(COMMAND "${CMAKE_COMMAND}" --build "${build_directory}" --parallel "${jobs}" --target ${objects}
    COMMAND_ERROR_IS_FATAL ANY)
  set(${patterns} "${selected}" PARENT_SCOPE)
  if(ARGC GREATER 5)
    set(${ARGV5} "${paths}" PARENT_SCOPE)
  endif()
endfunction()

include("${CMAKE_CURRENT_LIST_DIR}/../lib/tbc/cmake/tbcLifetimeCheck.cmake")

# Checks the blank lines that docs/code-style.md asks for between the statements of
# the selected translation units, and of the headers whose path matches HEADERS (a
# POSIX extended regular expression). Fails on the first one missing unless FIX is
# given, which inserts them instead. Existing blank lines are never removed.
function(telar_blank_line_check project_directory build_directory include_regex exclude_regex jobs)
  cmake_parse_arguments(PARSE_ARGV 5 arg "FIX" "HEADERS" "")
  tbc_find_linter("${project_directory}" linter)
  if(NOT EXISTS "${linter}")
    message(FATAL_ERROR "tbc-lint was not found at '${linter}'. Build lib/tbc with its release preset or set TBC_LINTER.")
  endif()
  telar_lint_prepare("${build_directory}" "${include_regex}" "${exclude_regex}" "${jobs}" patterns sources)
  if(arg_FIX)
    set(mode --fix)
  else()
    set(mode --warnings-as-errors)
  endif()
  if(arg_HEADERS)
    list(APPEND mode "--header-filter=${arg_HEADERS}")
  endif()
  execute_process(COMMAND "${linter}" --checks=blank-lines ${mode} "-p=${build_directory}" "-j=${jobs}" ${sources}
    WORKING_DIRECTORY "${project_directory}"
    COMMAND_ERROR_IS_FATAL ANY)
endfunction()
