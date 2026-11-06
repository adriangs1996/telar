get_filename_component(runtime_directory "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
if(NOT DEFINED RUNTIME_BUILD_DIRECTORY)
  set(RUNTIME_BUILD_DIRECTORY "${runtime_directory}/out")
endif()
get_filename_component(runtime_build_directory "${RUNTIME_BUILD_DIRECTORY}" ABSOLUTE)

if(NOT EXISTS "${runtime_build_directory}/compile_commands.json")
  message(FATAL_ERROR "No compile_commands.json in ${runtime_build_directory}; configure with tools/cpp configure runtime -B <directory> first")
endif()

if(NOT DEFINED JOBS)
  set(JOBS 2)
endif()
if(NOT JOBS MATCHES "^[1-9][0-9]*$")
  message(FATAL_ERROR "JOBS must be a positive integer")
endif()

# Let Ninja refresh CMake's database before selecting objects, including when a
# direct script invocation follows the addition of a target or module source.
execute_process(COMMAND "${CMAKE_COMMAND}" --build "${runtime_build_directory}"
    --parallel "${JOBS}" --target build.ninja
  COMMAND_ERROR_IS_FATAL ANY)

load_cache("${runtime_build_directory}" READ_WITH_PREFIX runtime_ CMAKE_CXX_COMPILER)
get_filename_component(runtime_compiler "${runtime_CMAKE_CXX_COMPILER}" REALPATH)
get_filename_component(runtime_compiler_directory "${runtime_compiler}" DIRECTORY)
find_program(runtime_clang_tidy NAMES clang-tidy HINTS "${runtime_compiler_directory}" NO_DEFAULT_PATH)
find_program(runtime_run_clang_tidy NAMES run-clang-tidy run-clang-tidy.py HINTS "${runtime_compiler_directory}" NO_DEFAULT_PATH)

if(NOT runtime_clang_tidy OR NOT runtime_run_clang_tidy)
  message(FATAL_ERROR "Install clang-tidy and run-clang-tidy from the same LLVM installation as the C++ compiler")
endif()

# Select once for both preparation and analysis. Object targets also prepare
# generated headers, module providers and dyndep/modmap files through Ninja,
# keeping preparation limited to those contexts and their dependencies.
file(READ "${runtime_build_directory}/compile_commands.json" commands)
string(JSON count LENGTH "${commands}")
set(objects)
set(patterns)
if(count GREATER 0)
  math(EXPR last "${count} - 1")
  foreach(index RANGE ${last})
    string(JSON source GET "${commands}" ${index} file)
    string(JSON directory GET "${commands}" ${index} directory)
    cmake_path(ABSOLUTE_PATH source BASE_DIRECTORY "${directory}" NORMALIZE)
    if(NOT source MATCHES "/(services/(runtime|cli)-cpp/|dlls/telar-platform/src/).*\\.(cpp|cppm)$"
        OR source MATCHES "/(services/(runtime|cli)-cpp/|dlls/telar-platform/src/)(.*/)?tests/")
      continue()
    endif()
    string(JSON output ERROR_VARIABLE error GET "${commands}" ${index} output)
    if(error)
      message(FATAL_ERROR "No object output for ${source}; regenerate the database with the pinned Ninja toolchain")
    endif()
    cmake_path(ABSOLUTE_PATH output BASE_DIRECTORY "${directory}" NORMALIZE)
    file(RELATIVE_PATH object "${runtime_build_directory}" "${output}")
    if(object MATCHES "^\\.\\./" OR IS_ABSOLUTE "${object}")
      message(FATAL_ERROR "Object output outside the build directory: ${output}")
    endif()
    list(APPEND objects "${object}")
    # run-clang-tidy treats positional filenames as Python regular expressions.
    string(REGEX REPLACE "([][+.*()?^$\\\\|])" "\\\\\\1" pattern "${source}")
    list(APPEND patterns "^${pattern}$")
  endforeach()
endif()
list(REMOVE_DUPLICATES objects)
list(REMOVE_DUPLICATES patterns)
if(NOT objects)
  message(FATAL_ERROR "No runtime, CLI or platform translation units found in the compilation database")
endif()

execute_process(COMMAND "${CMAKE_COMMAND}" --build "${runtime_build_directory}"
    --parallel "${JOBS}" --target ${objects}
  COMMAND_ERROR_IS_FATAL ANY)

execute_process(COMMAND "${runtime_clang_tidy}" --verify-config "--config-file=${runtime_directory}/.clang-tidy"
  COMMAND_ERROR_IS_FATAL ANY)
execute_process(COMMAND "${runtime_run_clang_tidy}"
    -clang-tidy-binary "${runtime_clang_tidy}"
    -config-file "${runtime_directory}/.clang-tidy"
    -p "${runtime_build_directory}" -j "${JOBS}"
    ${patterns}
  WORKING_DIRECTORY "${runtime_directory}"
  COMMAND_ERROR_IS_FATAL ANY)
