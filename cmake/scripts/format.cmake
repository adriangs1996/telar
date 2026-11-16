# Formats every C++, Objective-C++ and module file Git tracks outside vendored code with
# the root .clang-format, or with MODE=format-check fails on the first one that differs.
#   cmake [-DMODE=format-check] [-DCLANG_FORMAT=<path>] -P cmake/scripts/format.cmake
# The style needs the pinned clang-format, so only the repository toolchain is searched.
cmake_minimum_required(VERSION 3.25)

get_filename_component(root "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
if(NOT DEFINED MODE)
  set(MODE format)
endif()

if(MODE STREQUAL "format")
  set(arguments -i)
elseif(MODE STREQUAL "format-check")
  set(arguments --dry-run --Werror)
else()
  message(FATAL_ERROR "MODE must be format or format-check, not '${MODE}'")
endif()

find_program(CLANG_FORMAT NAMES clang-format HINTS "${root}/.toolchain/bin" NO_DEFAULT_PATH)
if(NOT CLANG_FORMAT)
  message(FATAL_ERROR "clang-format was not found in ${root}/.toolchain/bin. Run tools/cpp bootstrap or set CLANG_FORMAT.")
endif()

find_program(GIT NAMES git REQUIRED)

execute_process(
  COMMAND "${GIT}" ls-files --
    "*.cppm" "*.cpp" "*.cc" "*.cxx" "*.mm"
    "*.h" "*.hpp" "*.hh" "*.hxx" "*.ipp" "*.tpp"
    ":(exclude,glob)**/vendor/**" ":(exclude,glob)**/third_party/**"
  WORKING_DIRECTORY "${root}"
  OUTPUT_VARIABLE files
  COMMAND_ERROR_IS_FATAL ANY)

string(REPLACE "\n" ";" files "${files}")
list(FILTER files EXCLUDE REGEX "^$")
if(NOT files)
  message(FATAL_ERROR "Git tracks no C++ file under ${root}")
endif()

execute_process(
  COMMAND "${CLANG_FORMAT}" --style=file ${arguments} ${files}
  WORKING_DIRECTORY "${root}"
  COMMAND_ERROR_IS_FATAL ANY)
