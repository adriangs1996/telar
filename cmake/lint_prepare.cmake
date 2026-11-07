include_guard(GLOBAL)

# Build what every selected compile command reads before clang-tidy runs it:
# generated headers, module providers, dyndep/modmap files and the BMIs of
# CMake's synthetic module targets. clang-tidy analyses each database entry of
# a source, and an entry whose BMI is missing parses into an invalid AST that
# checks then walk. Sets <patterns> to run-clang-tidy file patterns.
function(telar_lint_prepare build_directory include_regex exclude_regex jobs patterns)
  # Let Ninja refresh CMake's database first, including after a new target or module.
  execute_process(COMMAND "${CMAKE_COMMAND}" --build "${build_directory}" --parallel "${jobs}" --target build.ninja
    COMMAND_ERROR_IS_FATAL ANY)
  file(READ "${build_directory}/compile_commands.json" commands)
  string(JSON count LENGTH "${commands}")
  set(objects)
  set(selected)
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
      # run-clang-tidy treats positional filenames as Python regular expressions.
      string(REGEX REPLACE "([][+.*()?^$\\\\|])" "\\\\\\1" pattern "${source}")
      list(APPEND selected "^${pattern}$")
    endforeach()
  endif()
  list(REMOVE_DUPLICATES objects)
  list(REMOVE_DUPLICATES selected)
  if(NOT objects)
    message(FATAL_ERROR "No translation units in ${build_directory} match ${include_regex}")
  endif()
  execute_process(COMMAND "${CMAKE_COMMAND}" --build "${build_directory}" --parallel "${jobs}" --target ${objects}
    COMMAND_ERROR_IS_FATAL ANY)
  set(${patterns} "${selected}" PARENT_SCOPE)
endfunction()
