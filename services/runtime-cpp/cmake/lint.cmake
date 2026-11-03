get_filename_component(runtime_directory "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
set(runtime_build_directory "${runtime_directory}/out")

if(NOT EXISTS "${runtime_build_directory}/compile_commands.json")
  message(FATAL_ERROR "Run just runtime-editor to generate the compilation database and headers first")
endif()

load_cache("${runtime_build_directory}" READ_WITH_PREFIX runtime_ CMAKE_CXX_COMPILER)
get_filename_component(runtime_compiler_directory "${runtime_CMAKE_CXX_COMPILER}" DIRECTORY)
find_program(runtime_clang_tidy NAMES clang-tidy HINTS "${runtime_compiler_directory}")
find_program(runtime_run_clang_tidy NAMES run-clang-tidy run-clang-tidy.py HINTS "${runtime_compiler_directory}")

if(NOT runtime_clang_tidy OR NOT runtime_run_clang_tidy)
  message(FATAL_ERROR "Install clang-tidy and run-clang-tidy from the same LLVM installation as the C++ compiler")
endif()

if(NOT DEFINED JOBS)
  set(JOBS 2)
endif()

execute_process(COMMAND "${runtime_clang_tidy}" --verify-config "--config-file=${runtime_directory}/.clang-tidy"
  COMMAND_ERROR_IS_FATAL ANY)
execute_process(COMMAND "${runtime_run_clang_tidy}"
    -clang-tidy-binary "${runtime_clang_tidy}"
    -config-file "${runtime_directory}/.clang-tidy"
    -p "${runtime_build_directory}" -j "${JOBS}"
    "/(services/runtime-cpp/(?!(?:.*/)?tests/)|dlls/telar-platform/src/).*\\.cpp$"
  WORKING_DIRECTORY "${runtime_directory}"
  COMMAND_ERROR_IS_FATAL ANY)
