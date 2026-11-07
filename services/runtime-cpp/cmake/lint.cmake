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

load_cache("${runtime_build_directory}" READ_WITH_PREFIX runtime_ CMAKE_CXX_COMPILER)
get_filename_component(runtime_compiler "${runtime_CMAKE_CXX_COMPILER}" REALPATH)
get_filename_component(runtime_compiler_directory "${runtime_compiler}" DIRECTORY)
find_program(runtime_clang_tidy NAMES clang-tidy HINTS "${runtime_compiler_directory}" NO_DEFAULT_PATH)
find_program(runtime_run_clang_tidy NAMES run-clang-tidy run-clang-tidy.py HINTS "${runtime_compiler_directory}" NO_DEFAULT_PATH)

if(NOT runtime_clang_tidy OR NOT runtime_run_clang_tidy)
  message(FATAL_ERROR "Install clang-tidy and run-clang-tidy from the same LLVM installation as the C++ compiler")
endif()

include("${runtime_directory}/../../cmake/lint_prepare.cmake")
telar_lint_prepare("${runtime_build_directory}"
  "/(services/(runtime|cli)-cpp/|dlls/telar-platform/src/).*\\.(cpp|cppm)$"
  "/(services/(runtime|cli)-cpp/|dlls/telar-platform/src/)(.*/)?tests/"
  "${JOBS}" patterns)

execute_process(COMMAND "${runtime_clang_tidy}" --verify-config "--config-file=${runtime_directory}/.clang-tidy"
  COMMAND_ERROR_IS_FATAL ANY)
execute_process(COMMAND "${runtime_run_clang_tidy}"
    -clang-tidy-binary "${runtime_clang_tidy}"
    -config-file "${runtime_directory}/.clang-tidy"
    -p "${runtime_build_directory}" -j "${JOBS}"
    ${patterns}
  WORKING_DIRECTORY "${runtime_directory}"
  COMMAND_ERROR_IS_FATAL ANY)
