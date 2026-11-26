# Runs one quality check of cmake/TelarChecks.cmake over a configured tree:
#   cmake -DCHECK=<check> -DBUILD_DIRECTORY=<tree> [-DJOBS=<n>] [-DFIX=ON] [-DFULL=ON] [-DDEEP=ON]
#         [-DTBC_LINTER=<path>] -P cmake/scripts/check.cmake
# CHECK is lint, analyze, lifetime, blank_lines, interface_bodies or standard_containers; its scope is
# the list of sources <tree>/checks/<check>.txt, which configuring the tree writes. The last four are
# tbc-lint's, and several of them joined with +, as lifetime+interface_bodies+blank_lines, run in one
# pass that parses each source once and applies to it the checks whose scope lists it. lint runs clang-tidy
# without its static analyzer, and analyze runs only the analyzer over lint's scope: it takes most of
# clang-tidy's time, and with DEEP five times as much. JOBS defaults to the physical core count; to half of it for those two when
# clang-tidy runs without tbc's plugin, tbc-tidy-scope, as it then reads every BMI its unit imports. FIX
# makes blank_lines insert the missing blank lines instead of failing on them. Every check checks only the
# units whose object, profile, linter, allowlist or, for checks run together, scope changed since their last check, and reports the others
# as they did then; FULL checks them all, and so does FIX.
cmake_minimum_required(VERSION 3.25)

get_filename_component(root "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
include("${root}/lib/tbc/cmake/tbcLifetimeCheck.cmake")

set(checks lint analyze lifetime bounds blank_lines interface_bodies standard_containers)
string(REPLACE "+" ";" selected "${CHECK}")
list(LENGTH selected selected_count)
foreach(check IN LISTS selected)
  if(NOT check IN_LIST checks)
    message(FATAL_ERROR "CHECK must be one of ${checks}, or several of tbc-lint's joined with +, not '${CHECK}'")
  endif()
  if(selected_count GREATER 1 AND (check STREQUAL "lint" OR check STREQUAL "analyze" OR FIX))
    message(FATAL_ERROR "Only tbc-lint's checks run together, and none of them with FIX; CHECK is '${CHECK}'")
  endif()
endforeach()
if(selected_count EQUAL 0)
  message(FATAL_ERROR "Set CHECK to one of ${checks}")
endif()
if(NOT BUILD_DIRECTORY)
  message(FATAL_ERROR "Set BUILD_DIRECTORY to a configured build tree")
endif()
get_filename_component(build "${BUILD_DIRECTORY}" ABSOLUTE)
if(NOT EXISTS "${build}/compile_commands.json")
  message(FATAL_ERROR "No compile_commands.json in ${build}; configure it with tools/cpp configure first")
endif()
load_cache("${build}" READ_WITH_PREFIX tree_ CMAKE_HOME_DIRECTORY CMAKE_CXX_COMPILER CMAKE_MAKE_PROGRAM)
set(project "${tree_CMAKE_HOME_DIRECTORY}")

set(default_jobs FALSE)
if(NOT JOBS)
  cmake_host_system_information(RESULT JOBS QUERY NUMBER_OF_PHYSICAL_CORES)
  set(default_jobs TRUE)
endif()
# analyze analyses the sources lint does; bounds checks the sources lifetime does.
set(scope_checks)
foreach(check IN LISTS selected)
  if(check STREQUAL "analyze")
    list(APPEND scope_checks lint)
  elseif(check STREQUAL "bounds")
    list(APPEND scope_checks lifetime)
  else()
    list(APPEND scope_checks "${check}")
  endif()
endforeach()
list(REMOVE_DUPLICATES scope_checks)
if(NOT JOBS MATCHES "^[1-9][0-9]*$")
  message(FATAL_ERROR "JOBS must be a positive integer")
endif()

# Builds what every selected compile command reads before a tool parses it: generated
# headers, module providers, dyndep/modmap files and the BMIs of CMake's synthetic
# module targets. A tool analyses each database entry of a source, and an entry whose
# BMI is missing parses into an invalid AST that checks then walk. Sets <sources> to the
# selected source paths and check_units to their source|object pairs.
function(telar_check_prepare sources)
  # Let Ninja refresh CMake's database and the scope first, including after a new target
  # or module.
  execute_process(COMMAND "${CMAKE_COMMAND}" --build "${build}" --parallel "${JOBS}" --target build.ninja
    COMMAND_ERROR_IS_FATAL ANY)
  set(scope)
  foreach(check IN LISTS scope_checks)
    if(NOT EXISTS "${build}/checks/${check}.txt")
      message(FATAL_ERROR "No target of ${build} registers for ${check}")
    endif()
    file(STRINGS "${build}/checks/${check}.txt" listed)
    list(APPEND scope ${listed})
  endforeach()
  list(REMOVE_DUPLICATES scope)
  # CMake's Ninja generator writes one field per line, so reading the directory, file and output
  # lines in order is the database without parsing all of it once per entry, which string(JSON)
  # would do for each field it reads.
  file(STRINGS "${build}/compile_commands.json" fields REGEX "^  \"(directory|file|output)\": ")
  set(objects)
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
  endforeach()
  list(REMOVE_DUPLICATES objects)
  list(REMOVE_DUPLICATES paths)
  if(NOT objects)
    message(FATAL_ERROR "No translation unit of ${build} is in the scope of ${CHECK}")
  endif()
  execute_process(COMMAND "${CMAKE_COMMAND}" --build "${build}" --parallel "${JOBS}" --target ${objects}
    COMMAND_ERROR_IS_FATAL ANY)
  set(${sources} "${paths}" PARENT_SCOPE)
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

if(CHECK STREQUAL "lint" OR CHECK STREQUAL "analyze")
  get_filename_component(compiler "${tree_CMAKE_CXX_COMPILER}" REALPATH)
  get_filename_component(compiler_directory "${compiler}" DIRECTORY)
  find_program(clang_tidy NAMES clang-tidy HINTS "${compiler_directory}" NO_DEFAULT_PATH)
  if(NOT clang_tidy)
    message(FATAL_ERROR "Install clang-tidy from the same LLVM installation as the C++ compiler")
  endif()
  find_program(python NAMES python3 REQUIRED)
  execute_process(COMMAND "${clang_tidy}" --version OUTPUT_VARIABLE version COMMAND_ERROR_IS_FATAL ANY)
  string(REGEX MATCH "version ([0-9]+)" version_match "${version}")
  if(NOT version_match OR CMAKE_MATCH_1 LESS 23)
    message(FATAL_ERROR "The lint profiles require clang-tidy 23 or newer; found ${clang_tidy}")
  endif()
  # Each source is analysed with the .clang-tidy nearest it, its project's profile; the
  # scope holds only sources that have one, and configuring lists the profiles.
  file(STRINGS "${build}/checks/lint-profiles.txt" profiles)
  foreach(profile IN LISTS profiles)
    execute_process(COMMAND "${clang_tidy}" --verify-config "--config-file=${profile}"
      COMMAND_ERROR_IS_FATAL ANY)
  endforeach()
  # Every profile enables the analyzer whole, so analyze keeps only it and lint everything else.
  set(analyzer_options)
  if(CHECK STREQUAL "analyze")
    set(checks_option "-*,clang-analyzer-*")
    # The analyzer follows a function into the templates it calls, telar::ds above all, until its budget
    # for the function runs out, which is where four fifths of its time go. Its shallow mode explores each
    # function a few calls deep and reports the same on this tree; DEEP asks for the whole analysis.
    if(NOT DEEP)
      set(analyzer_options --extra-arg=-Xclang --extra-arg=-analyzer-config --extra-arg=-Xclang --extra-arg=mode=shallow)
    endif()
  else()
    set(checks_option "-clang-analyzer-*")
  endif()
  # With tbc's plugin the checks walk only what each unit parses itself; without it they report the
  # same and also walk every module the unit imports, which takes several times as long.
  tbc_find_linter("${project}" linter)
  set(plugin_option)
  if(linter)
    cmake_path(GET linter PARENT_PATH linter_directory)
    tbc_find_tidy_scope("${linter_directory}" "${clang_tidy}" scope)
    if(scope)
      string(APPEND checks_option ",tbc-parsed-scope")
      # With the tree's Ninja the run also gives each header of the project to one of the units that
      # include it, instead of checking it once per unit.
      set(plugin_option --plugin "${scope}" --ninja "${tree_CMAKE_MAKE_PROGRAM}")
    endif()
  endif()
  if(NOT plugin_option)
    message(STATUS "${CHECK}: tbc-tidy-scope is not built or this clang-tidy does not load it, so each unit walks all it imports")
    if(default_jobs)
      math(EXPR JOBS "(${JOBS} + 1) / 2")
    endif()
  endif()
  telar_check_prepare(sources)
  # Each unit's stamp and the fixes it exported, a directory clang-apply-replacements reads.
  set(stamps "${build}/checks/stamps/${CHECK}")
  if(FULL)
    file(REMOVE_RECURSE "${stamps}")
  endif()
  list(JOIN check_units "\n" listed)
  file(WRITE "${build}/checks/${CHECK}.units" "${listed}\n")
  execute_process(COMMAND "${python}" "${CMAKE_CURRENT_LIST_DIR}/clang_tidy.py"
      --clang-tidy "${clang_tidy}" ${plugin_option} --build "${build}" --stamps "${stamps}" --jobs "${JOBS}"
      "--checks=${checks_option}" ${analyzer_options} --name "${CHECK}" "${build}/checks/${CHECK}.units"
    WORKING_DIRECTORY "${project}"
    COMMAND_ERROR_IS_FATAL ANY)
  return()
endif()

tbc_find_linter("${project}" linter)
if(NOT EXISTS "${linter}")
  message(FATAL_ERROR "tbc-lint was not found at '${linter}'. Build lib/tbc with its release preset or set TBC_LINTER.")
endif()
# What each selected check adds to one run of tbc-lint, and what decides its reports besides the
# sources: an allowlist, so a new one checks every unit again. Several checks in one pass apply to a
# unit the ones whose scope lists it, so a scope that changes checks every unit again too: a unit that
# enters or leaves one keeps its object, and its stamp would replay the checks it had. Configuring
# rewrites a scope only when its sources change.
set(names)
set(arguments)
set(inputs "${linter}")
foreach(check IN LISTS selected)
  string(REPLACE "_" "-" name "${check}")
  list(APPEND names "${name}")
  if(selected_count GREATER 1)
    set(scope_file "${build}/checks/${check}.txt")
    if(check STREQUAL "bounds")
      set(scope_file "${build}/checks/lifetime.txt")
    endif()
    list(APPEND arguments "--scope=${name}=${scope_file}")
    list(APPEND inputs "${scope_file}")
  endif()
  if(check STREQUAL "blank_lines")
    telar_repository_headers(headers)
    list(APPEND arguments "--header-filter=${headers}")
  elseif(check STREQUAL "standard_containers")
    list(APPEND arguments "--standard-containers-allowlist=${root}/docs/build/standard-containers-allowlist.txt")
    list(APPEND inputs "${root}/docs/build/standard-containers-allowlist.txt")
  elseif(check STREQUAL "interface_bodies")
    # Rule 3 of the module layout: an interface carries declarations, and function bodies
    # go to implementation units, except constexpr ones and the hot paths marked
    # TBC_HOT_PATH. The allowlist names the modules that still keep bodies; the check
    # fails on any other module with one, and on an allowed module whose checked
    # interfaces keep none.
    list(APPEND arguments "--interface-allowlist=${root}/docs/build/interface-bodies-allowlist.txt")
    list(APPEND inputs "${root}/docs/build/interface-bodies-allowlist.txt")
  endif()
endforeach()
list(JOIN names "," names)
list(PREPEND arguments "--checks=${names}")
if(FIX)
  list(APPEND arguments --fix)
else()
  list(APPEND arguments --warnings-as-errors)
endif()

telar_check_prepare(sources)

# Each unit is checked on its own, so a unit whose object and tbc-lint are older than the stamp its
# last check left reports what it reported then, which tbc-lint replays: Ninja has rebuilt every
# object whose source, headers or imported modules changed. A run that fixes rewrites the sources it
# reports on, so it checks them all and leaves no stamp.
if(NOT FIX)
  set(stamps "${build}/checks/stamps/${CHECK}")
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
