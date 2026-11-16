# Runs one quality check of cmake/TelarChecks.cmake over a configured tree:
#   cmake -DCHECK=<check> -DBUILD_DIRECTORY=<tree> [-DJOBS=<n>] [-DFIX=ON] [-DTBC_LINTER=<path>]
#         -P cmake/scripts/check.cmake
# CHECK is lint, lifetime, blank_lines or interface_bodies; its scope is the list of
# sources <tree>/checks/<check>.txt, which configuring the tree writes. JOBS defaults to
# 2 for lint and to the physical core count otherwise. FIX makes blank_lines insert the
# missing blank lines instead of failing on them.
cmake_minimum_required(VERSION 3.25)

get_filename_component(root "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
include("${root}/lib/tbc/cmake/tbcLifetimeCheck.cmake")

set(checks lint lifetime blank_lines interface_bodies)
if(NOT CHECK IN_LIST checks)
  message(FATAL_ERROR "CHECK must be one of ${checks}, not '${CHECK}'")
endif()
if(NOT BUILD_DIRECTORY)
  message(FATAL_ERROR "Set BUILD_DIRECTORY to a configured build tree")
endif()
get_filename_component(build "${BUILD_DIRECTORY}" ABSOLUTE)
if(NOT EXISTS "${build}/compile_commands.json")
  message(FATAL_ERROR "No compile_commands.json in ${build}; configure it with tools/cpp configure first")
endif()
load_cache("${build}" READ_WITH_PREFIX tree_ CMAKE_HOME_DIRECTORY CMAKE_CXX_COMPILER)
set(project "${tree_CMAKE_HOME_DIRECTORY}")

if(NOT JOBS)
  if(CHECK STREQUAL "lint")
    set(JOBS 2)
  else()
    cmake_host_system_information(RESULT JOBS QUERY NUMBER_OF_PHYSICAL_CORES)
  endif()
endif()
if(NOT JOBS MATCHES "^[1-9][0-9]*$")
  message(FATAL_ERROR "JOBS must be a positive integer")
endif()

# Builds what every selected compile command reads before a tool parses it: generated
# headers, module providers, dyndep/modmap files and the BMIs of CMake's synthetic
# module targets. A tool analyses each database entry of a source, and an entry whose
# BMI is missing parses into an invalid AST that checks then walk. Sets <sources> to the
# selected source paths and <patterns> to them as run-clang-tidy file patterns.
function(telar_check_prepare sources patterns)
  # Let Ninja refresh CMake's database and the scope first, including after a new target
  # or module.
  execute_process(COMMAND "${CMAKE_COMMAND}" --build "${build}" --parallel "${JOBS}" --target build.ninja
    COMMAND_ERROR_IS_FATAL ANY)
  if(NOT EXISTS "${build}/checks/${CHECK}.txt")
    message(FATAL_ERROR "No target of ${build} registers for ${CHECK}")
  endif()
  file(STRINGS "${build}/checks/${CHECK}.txt" scope)
  file(READ "${build}/compile_commands.json" commands)
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
      if(NOT source IN_LIST scope)
        continue()
      endif()
      string(JSON output ERROR_VARIABLE error GET "${commands}" ${index} output)
      if(error)
        message(FATAL_ERROR "No object output for ${source}; regenerate the database with the pinned Ninja toolchain")
      endif()
      cmake_path(ABSOLUTE_PATH output BASE_DIRECTORY "${directory}" NORMALIZE)
      file(RELATIVE_PATH object "${build}" "${output}")
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
    message(FATAL_ERROR "No translation unit of ${build} is in the scope of ${CHECK}")
  endif()
  execute_process(COMMAND "${CMAKE_COMMAND}" --build "${build}" --parallel "${JOBS}" --target ${objects}
    COMMAND_ERROR_IS_FATAL ANY)
  set(${sources} "${paths}" PARENT_SCOPE)
  set(${patterns} "${selected}" PARENT_SCOPE)
endfunction()

# Sets <out> to a POSIX extended regular expression for the headers of the projects
# under src/ and lib/, for blank_lines: neither what their build folders (out, out-*)
# generate nor what an include path reaches through `..`, as vendor/.
function(telar_repository_headers out)
  string(REGEX REPLACE "([][+.*()?^$\\|{}])" "\\\\\\1" escaped "${root}")
  # A path component that is neither `..` nor, right below the project, out or out-*.
  set(component "([^./][^/]*|\\.[^./][^/]*|\\.)")
  set(first "([^./o][^/]*|\\.[^./][^/]*|\\.|o|o[^u/][^/]*|ou|ou[^t/][^/]*|out[^-/][^/]*)")
  set(${out} "^${escaped}/(src|lib)/[^/]+/(\\./)*${first}(/${component})*$" PARENT_SCOPE)
endfunction()

if(CHECK STREQUAL "lint")
  get_filename_component(compiler "${tree_CMAKE_CXX_COMPILER}" REALPATH)
  get_filename_component(compiler_directory "${compiler}" DIRECTORY)
  find_program(clang_tidy NAMES clang-tidy HINTS "${compiler_directory}" NO_DEFAULT_PATH)
  find_program(run_clang_tidy NAMES run-clang-tidy run-clang-tidy.py HINTS "${compiler_directory}" NO_DEFAULT_PATH)
  if(NOT clang_tidy OR NOT run_clang_tidy)
    message(FATAL_ERROR "Install clang-tidy and run-clang-tidy from the same LLVM installation as the C++ compiler")
  endif()
  execute_process(COMMAND "${clang_tidy}" --version OUTPUT_VARIABLE version COMMAND_ERROR_IS_FATAL ANY)
  string(REGEX MATCH "version ([0-9]+)" version_match "${version}")
  if(NOT version_match OR CMAKE_MATCH_1 LESS 23)
    message(FATAL_ERROR "The lint profiles require clang-tidy 23 or newer; found ${clang_tidy}")
  endif()
  if(EXISTS "${project}/.clang-tidy")
    execute_process(COMMAND "${clang_tidy}" --verify-config "--config-file=${project}/.clang-tidy"
      COMMAND_ERROR_IS_FATAL ANY)
  endif()

  telar_check_prepare(sources patterns)
  # Each source is analysed with the .clang-tidy nearest it, its project's profile.
  execute_process(COMMAND "${run_clang_tidy}"
      -clang-tidy-binary "${clang_tidy}"
      -p "${build}" -j "${JOBS}"
      -export-fixes "${build}/clang-tidy.yaml"
      -quiet
      ${patterns}
    WORKING_DIRECTORY "${project}"
    COMMAND_ERROR_IS_FATAL ANY)
  return()
endif()

tbc_find_linter("${project}" linter)
if(NOT EXISTS "${linter}")
  message(FATAL_ERROR "tbc-lint was not found at '${linter}'. Build lib/tbc with its release preset or set TBC_LINTER.")
endif()
if(CHECK STREQUAL "lifetime")
  set(arguments --warnings-as-errors)
elseif(CHECK STREQUAL "blank_lines")
  telar_repository_headers(headers)
  if(FIX)
    set(arguments --checks=blank-lines --fix "--header-filter=${headers}")
  else()
    set(arguments --checks=blank-lines --warnings-as-errors "--header-filter=${headers}")
  endif()
else()
  # Rule 3 of the module layout: an interface carries declarations, and function bodies
  # go to implementation units, except constexpr ones and the hot paths marked
  # TBC_HOT_PATH. The allowlist names the modules that still keep bodies; the check
  # fails on any other module with one, and on an allowed module whose checked
  # interfaces keep none.
  set(arguments --checks=interface-bodies --warnings-as-errors "--interface-allowlist=${root}/docs/build/interface-bodies-allowlist.txt")
endif()

telar_check_prepare(sources patterns)
execute_process(COMMAND "${linter}" ${arguments} "-p=${build}" "-j=${JOBS}" ${sources}
  WORKING_DIRECTORY "${project}"
  COMMAND_ERROR_IS_FATAL ANY)
