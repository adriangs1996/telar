cmake_minimum_required(VERSION 3.25)

if(MODE STREQUAL "lint")
  find_program(CLANG_TIDY NAMES clang-tidy HINTS "${COMPILER_DIR}")
  if(NOT CLANG_TIDY)
    message(FATAL_ERROR "clang-tidy was not found. Add your LLVM bin directory to PATH.")
  endif()

  set(database "${BINARY_DIR}/compile_commands.json")
  if(NOT EXISTS "${database}")
    message(FATAL_ERROR "No compilation database at ${database}. Configure with a Ninja or Makefiles generator first.")
  endif()

  file(READ "${database}" commands)
  string(JSON count LENGTH "${commands}")
  if(count EQUAL 0)
    message(FATAL_ERROR "The compilation database is empty.")
  endif()

  math(EXPR last "${count} - 1")
  set(sources)
  foreach(index RANGE ${last})
    string(JSON source GET "${commands}" ${index} file)
    cmake_path(IS_PREFIX SOURCE_DIR "${source}" NORMALIZE in_project_directory)
    cmake_path(IS_PREFIX BINARY_DIR "${source}" NORMALIZE in_build_directory)
    if(in_project_directory AND NOT in_build_directory AND NOT source MATCHES "/(out|build[^/]*|cmake-build[^/]*|vendor|third_party|generated)/")
      list(APPEND sources "${source}")
    endif()
  endforeach()
  list(REMOVE_DUPLICATES sources)
  if(NOT sources)
    message(FATAL_ERROR "No project translation units were found in the compilation database.")
  endif()

  execute_process(
    COMMAND "${CLANG_TIDY}" "-p=${BINARY_DIR}" "--config-file=${SOURCE_DIR}/.clang-tidy" ${sources}
    WORKING_DIRECTORY "${SOURCE_DIR}"
    COMMAND_ERROR_IS_FATAL ANY)
elseif(MODE STREQUAL "format" OR MODE STREQUAL "format-check")
  find_program(CLANG_FORMAT NAMES clang-format HINTS "${COMPILER_DIR}")
  if(NOT CLANG_FORMAT)
    message(FATAL_ERROR "clang-format was not found. Add your LLVM bin directory to PATH.")
  endif()

  file(GLOB_RECURSE sources
    "${SOURCE_DIR}/*.cpp" "${SOURCE_DIR}/*.cc" "${SOURCE_DIR}/*.cxx"
    "${SOURCE_DIR}/*.h" "${SOURCE_DIR}/*.hpp" "${SOURCE_DIR}/*.hh" "${SOURCE_DIR}/*.hxx"
    "${SOURCE_DIR}/*.ipp" "${SOURCE_DIR}/*.tpp")
  list(FILTER sources EXCLUDE REGEX "/(out|build[^/]*|cmake-build[^/]*|\\.git|vendor|third_party|generated)/")
  foreach(source IN LISTS sources)
    cmake_path(IS_PREFIX BINARY_DIR "${source}" NORMALIZE in_build_directory)
    if(in_build_directory)
      list(REMOVE_ITEM sources "${source}")
    endif()
  endforeach()

  if(MODE STREQUAL "format-check")
    set(arguments --dry-run --Werror)
  else()
    set(arguments -i)
  endif()

  if(sources)
    execute_process(
      COMMAND "${CLANG_FORMAT}" "--style=file:${SOURCE_DIR}/.clang-format" ${arguments} ${sources}
      WORKING_DIRECTORY "${SOURCE_DIR}"
      COMMAND_ERROR_IS_FATAL ANY)
  endif()
else()
  message(FATAL_ERROR "Unknown tooling mode: ${MODE}")
endif()
