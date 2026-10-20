get_filename_component(desktop_directory "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)

find_program(desktop_clang_format NAMES clang-format)

if(NOT desktop_clang_format AND APPLE)
  find_program(desktop_brew NAMES brew)

  if(desktop_brew)
    execute_process(COMMAND "${desktop_brew}" --prefix llvm
      OUTPUT_VARIABLE desktop_llvm_prefix OUTPUT_STRIP_TRAILING_WHITESPACE
      COMMAND_ERROR_IS_FATAL ANY)
    find_program(desktop_clang_format NAMES clang-format HINTS "${desktop_llvm_prefix}/bin")
  endif()
endif()

if(NOT desktop_clang_format)
  message(FATAL_ERROR "Install clang-format or set -Ddesktop_clang_format=/path/to/clang-format")
endif()

find_program(desktop_stylua NAMES stylua REQUIRED)

file(GLOB_RECURSE desktop_cpp_files
  "${desktop_directory}/*.c" "${desktop_directory}/*.h"
  "${desktop_directory}/*.cpp" "${desktop_directory}/*.hpp"
  "${desktop_directory}/*.cppm" "${desktop_directory}/*.m" "${desktop_directory}/*.mm")
list(FILTER desktop_cpp_files EXCLUDE REGEX "/(out|zig-out|\\.zig-cache|vendor|third_party)/")

if(CHECK)
  set(clang_format_arguments --dry-run --Werror)
  set(stylua_arguments --check)
else()
  set(clang_format_arguments -i)
  set(stylua_arguments)
endif()

execute_process(COMMAND "${desktop_clang_format}" --style=file ${clang_format_arguments} ${desktop_cpp_files}
  WORKING_DIRECTORY "${desktop_directory}"
  COMMAND_ERROR_IS_FATAL ANY)
execute_process(COMMAND "${desktop_stylua}" --verify ${stylua_arguments}
    --config-path "${desktop_directory}/.stylua.toml" "${desktop_directory}/ui"
  WORKING_DIRECTORY "${desktop_directory}"
  COMMAND_ERROR_IS_FATAL ANY)
