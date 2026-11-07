get_filename_component(gui_directory "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)

if(NOT DEFINED GUI_BUILD_DIRECTORY)
  set(GUI_BUILD_DIRECTORY "${gui_directory}/out")
endif()

if(NOT EXISTS "${GUI_BUILD_DIRECTORY}/compile_commands.json")
  message(FATAL_ERROR "Configure and build gui-cpp before running gui-lint")
endif()

load_cache("${GUI_BUILD_DIRECTORY}" READ_WITH_PREFIX gui_ CMAKE_CXX_COMPILER)
get_filename_component(gui_compiler_directory "${gui_CMAKE_CXX_COMPILER}" DIRECTORY)
find_program(gui_clang_tidy NAMES clang-tidy HINTS "${gui_compiler_directory}")
find_program(gui_run_clang_tidy NAMES run-clang-tidy run-clang-tidy.py HINTS "${gui_compiler_directory}")

if(NOT gui_clang_tidy OR NOT gui_run_clang_tidy)
  message(FATAL_ERROR "Install clang-tidy and run-clang-tidy from the C++ compiler's LLVM installation")
endif()

execute_process(
  COMMAND "${gui_clang_tidy}" --version
  OUTPUT_VARIABLE gui_clang_tidy_version
  COMMAND_ERROR_IS_FATAL ANY)
string(REGEX MATCH "version ([0-9]+)" gui_clang_tidy_version_match "${gui_clang_tidy_version}")
if(NOT gui_clang_tidy_version_match OR CMAKE_MATCH_1 LESS 23)
  message(FATAL_ERROR "The GUI lint profile requires clang-tidy 23 or newer; found ${gui_clang_tidy}")
endif()

if(NOT DEFINED GUI_LINT_JOBS)
  set(GUI_LINT_JOBS 2)
endif()

execute_process(
  COMMAND "${gui_clang_tidy}" --verify-config "--config-file=${gui_directory}/.clang-tidy"
  COMMAND_ERROR_IS_FATAL ANY)

get_filename_component(gui_build_directory "${GUI_BUILD_DIRECTORY}" ABSOLUTE)
include("${gui_directory}/../../cmake/lint_prepare.cmake")
telar_lint_prepare("${gui_build_directory}" "/services/gui-cpp/.*\\.(cpp|cppm|mm)$" "/services/gui-cpp/out[^/]*/"
  "${GUI_LINT_JOBS}" gui_patterns)

execute_process(
  COMMAND "${gui_run_clang_tidy}"
    -clang-tidy-binary "${gui_clang_tidy}"
    -config-file "${gui_directory}/.clang-tidy"
    -p "${gui_build_directory}"
    -j "${GUI_LINT_JOBS}"
    -export-fixes "${gui_build_directory}/clang-tidy.yaml"
    -quiet
    ${gui_patterns}
  WORKING_DIRECTORY "${gui_directory}"
  COMMAND_ERROR_IS_FATAL ANY)
