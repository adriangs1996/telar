# Runs one quality check of cmake/TelarChecks.cmake over a configured tree:
#   cmake -DCHECK=<check> -DBUILD_DIRECTORY=<tree> [-DJOBS=<n>] [-DFIX=ON] [-DFULL=ON]
#         [-DTBC_LINTER=<path>] -P cmake/scripts/check.cmake
# CHECK is lint, lifetime, blank_lines, interface_bodies or standard_containers; its scope is the list of
# sources <tree>/checks/<check>.txt, which configuring the tree writes. JOBS defaults to
# 2 for lint and to the physical core count otherwise. FIX makes blank_lines insert the
# missing blank lines instead of failing on them. lifetime and standard_containers check only the
# units whose object, tbc-lint or allowlist changed since their last check, and report the others as
# they did then; FULL checks them all.
cmake_minimum_required(VERSION 3.25)

get_filename_component(root "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
include("${root}/lib/tbc/cmake/tbcLifetimeCheck.cmake")

set(checks lint lifetime blank_lines interface_bodies standard_containers)
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
  # CMake's Ninja generator writes one field per line, so reading the directory, file and output
  # lines in order is the database without parsing all of it once per entry, which string(JSON)
  # would do for each field it reads.
  file(STRINGS "${build}/compile_commands.json" fields REGEX "^  \"(directory|file|output)\": ")
  set(objects)
  set(selected)
  set(paths)
  set(units)
  set(directory)
  set(source)
  set(scope_set ";${scope};")
  foreach(field IN LISTS fields)
    if(NOT field MATCHES "^  \"(directory|file|output)\": \"(.*)\",?$")
      message(FATAL_ERROR "Unexpected compile database line in ${build}: ${field}")
    endif()
    set(key "${CMAKE_MATCH_1}")
    set(value "${CMAKE_MATCH_2}")
    if(key STREQUAL "directory")
      set(directory "${value}")
      continue()
    endif()
    if(key STREQUAL "file")
      cmake_path(ABSOLUTE_PATH value BASE_DIRECTORY "${directory}" NORMALIZE OUTPUT_VARIABLE source)
      continue()
    endif()
    string(FIND "${scope_set}" ";${source};" in_scope)
    if(in_scope EQUAL -1)
      continue()
    endif()
    cmake_path(ABSOLUTE_PATH value BASE_DIRECTORY "${directory}" NORMALIZE OUTPUT_VARIABLE output)
    file(RELATIVE_PATH object "${build}" "${output}")
    if(object MATCHES "^\\.\\./" OR IS_ABSOLUTE "${object}")
      message(FATAL_ERROR "Object output outside the build directory: ${output}")
    endif()
    list(APPEND objects "${object}")
    list(APPEND paths "${source}")
    list(APPEND units "${source}|${output}")
    # run-clang-tidy treats positional filenames as Python regular expressions.
    string(REGEX REPLACE "([][+.*()?^$\\\\|])" "\\\\\\1" pattern "${source}")
    list(APPEND selected "^${pattern}$")
  endforeach()
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
  set(check_units "${units}" PARENT_SCOPE)
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
  telar_check_prepare(sources patterns)
  # Each source is analysed with the .clang-tidy nearest it, its project's profile; the
  # scope holds only sources that have one, and configuring lists the profiles.
  file(STRINGS "${build}/checks/lint-profiles.txt" profiles)
  foreach(profile IN LISTS profiles)
    execute_process(COMMAND "${clang_tidy}" --verify-config "--config-file=${profile}"
      COMMAND_ERROR_IS_FATAL ANY)
  endforeach()
  # run-clang-tidy first lists the checks of the working directory, the project root,
  # which has no profile of its own: -allow-no-checks lets that probe pass. Every source
  # in the scope has a profile, so none is analysed without checks.
  execute_process(COMMAND "${run_clang_tidy}"
      -clang-tidy-binary "${clang_tidy}"
      -p "${build}" -j "${JOBS}"
      -export-fixes "${build}/clang-tidy.yaml"
      -allow-no-checks
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
elseif(CHECK STREQUAL "standard_containers")
  set(arguments --checks=standard-containers --warnings-as-errors "--standard-containers-allowlist=${root}/docs/build/standard-containers-allowlist.txt")
else()
  # Rule 3 of the module layout: an interface carries declarations, and function bodies
  # go to implementation units, except constexpr ones and the hot paths marked
  # TBC_HOT_PATH. The allowlist names the modules that still keep bodies; the check
  # fails on any other module with one, and on an allowed module whose checked
  # interfaces keep none.
  set(arguments --checks=interface-bodies --warnings-as-errors "--interface-allowlist=${root}/docs/build/interface-bodies-allowlist.txt")
endif()

telar_check_prepare(sources patterns)

# Each unit is checked on its own, so a unit whose object and tbc-lint are older than the stamp its
# last check left reports what it reported then, which tbc-lint replays: Ninja has rebuilt every
# object whose source, headers or imported modules changed.
if(CHECK STREQUAL "lifetime" OR CHECK STREQUAL "standard_containers")
  set(stamps "${build}/checks/stamps/${CHECK}")
  # The allowlist decides what standard_containers reports, so a new one checks every unit again.
  set(inputs "${linter}")
  if(CHECK STREQUAL "standard_containers")
    list(APPEND inputs "${root}/docs/build/standard-containers-allowlist.txt")
  endif()
  if(FULL)
    file(REMOVE_RECURSE "${stamps}")
  endif()
  file(MAKE_DIRECTORY "${stamps}")
  set(stale)
  set(fresh)
  foreach(unit IN LISTS check_units)
    string(REPLACE "|" ";" unit "${unit}")
    list(GET unit 0 source)
    list(GET unit 1 object)
    string(REPLACE "/" "%" name "${source}")
    set(stamp "${stamps}/${name}")
    set(current FALSE)
    if(EXISTS "${stamp}" AND NOT "${object}" IS_NEWER_THAN "${stamp}")
      set(current TRUE)
      foreach(input IN LISTS inputs)
        if("${input}" IS_NEWER_THAN "${stamp}")
          set(current FALSE)
        endif()
      endforeach()
    endif()
    if(current)
      list(APPEND fresh "${source}")
    else()
      list(APPEND stale "${source}")
    endif()
  endforeach()
  list(REMOVE_DUPLICATES stale)
  list(REMOVE_DUPLICATES fresh)
  if(stale AND fresh)
    list(REMOVE_ITEM fresh ${stale})
  endif()
  list(LENGTH sources total)
  list(LENGTH stale changed)
  message(STATUS "${CHECK}: ${changed} of ${total} units changed since their last check")
  list(JOIN fresh "\n" replayed)
  file(WRITE "${stamps}.replay" "${replayed}\n")
  set(sources ${stale})
  list(APPEND arguments "--stamps=${stamps}" "--replay=${stamps}.replay")
endif()

execute_process(COMMAND "${linter}" ${arguments} "-p=${build}" "-j=${JOBS}" ${sources}
  WORKING_DIRECTORY "${project}"
  COMMAND_ERROR_IS_FATAL ANY)
