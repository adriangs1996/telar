include_guard(GLOBAL)

# The quality checks of a configured tree. Each runs cmake/scripts/check.cmake on the
# sources of the targets that registered for it (telar_register_checks, which the
# helpers of TelarTargets.cmake call):
#
#   lint              clang-tidy, with the .clang-tidy nearest each source; a source with
#                     none in the project has no lint profile and is not linted
#   lifetime          tbc-lint's lifetime analysis
#   blank_lines       tbc-lint's blank lines of docs/code-style.md
#   interface_bodies  tbc-lint's rule that module interfaces keep no function bodies
#
# and format and format-check run cmake/scripts/format.cmake over every C++ file Git
# tracks.

# The quality checks a target can register for.
set(TELAR_CHECKS lint lifetime blank_lines interface_bodies)

set(TELAR_CHECK_JOBS "" CACHE STRING "Parallel processes of a quality check; empty uses each check's default")
set(TBC_LINTER "" CACHE FILEPATH "Path to tbc-lint; otherwise use the project .tbc.json or PATH")

# telar_register_checks(<target>... CHECKS <check>...): adds the sources of the targets
# to the scope of each check. The helpers of TelarTargets.cmake call it; a target they do
# not declare calls it itself.
function(telar_register_checks)
  cmake_parse_arguments(PARSE_ARGV 0 register "" "" "CHECKS")
  foreach(check IN LISTS register_CHECKS)
    if(NOT check IN_LIST TELAR_CHECKS)
      message(FATAL_ERROR "Unknown check '${check}'; the checks are ${TELAR_CHECKS}")
    endif()
  endforeach()
  foreach(target IN LISTS register_UNPARSED_ARGUMENTS)
    set_property(TARGET ${target} APPEND PROPERTY TELAR_CHECKS ${register_CHECKS})
    set_property(GLOBAL APPEND PROPERTY TELAR_CHECK_TARGETS ${target})
  endforeach()
endfunction()

# telar_checks([PREFIX <prefix>]): the check targets of the top-level project,
# <prefix>-lint, <prefix>-lifetime, <prefix>-blank-lines and <prefix>-interface-bodies
# (without PREFIX, lint, lifetime, ...) for each check some target registered for, and
# format and format-check. Their scope is written to <build>/checks/<check>.txt once the
# project is configured, so the call can come before the targets.
function(telar_checks)
  cmake_parse_arguments(PARSE_ARGV 0 checks "" "PREFIX" "")
  set(prefix "")
  if(checks_PREFIX)
    set(prefix "${checks_PREFIX}-")
  endif()
  set(script "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/scripts/format.cmake")
  add_custom_target(format
    COMMAND "${CMAKE_COMMAND}" -P "${script}"
    USES_TERMINAL
    VERBATIM)
  add_custom_target(format-check
    COMMAND "${CMAKE_COMMAND}" -DMODE=format-check -P "${script}"
    USES_TERMINAL
    VERBATIM)
  # A deferred call reads its arguments when it runs, so the prefix is written into it.
  cmake_language(EVAL CODE "cmake_language(DEFER DIRECTORY [[${CMAKE_SOURCE_DIR}]] CALL _telar_checks_define [[${prefix}]])")
endfunction()

# Writes the scope of each check and defines its target.
function(_telar_checks_define prefix)
  get_property(targets GLOBAL PROPERTY TELAR_CHECK_TARGETS)
  list(REMOVE_DUPLICATES targets)
  foreach(check IN LISTS TELAR_CHECKS)
    set(scope_${check})
  endforeach()
  foreach(target IN LISTS targets)
    _telar_check_sources(${target} sources)
    get_target_property(checks ${target} TELAR_CHECKS)
    if(NOT checks)
      continue()
    endif()
    list(REMOVE_DUPLICATES checks)
    foreach(check IN LISTS checks)
      if(check STREQUAL "interface_bodies")
        set(pattern "\\.cppm$")
      else()
        set(pattern "\\.(cpp|cppm|mm)$")
      endif()
      set(selected ${sources})
      list(FILTER selected INCLUDE REGEX "${pattern}")
      list(APPEND scope_${check} ${selected})
    endforeach()
  endforeach()

  # clang-tidy analyses a source with the .clang-tidy nearest it, its project's profile. A
  # folder without one has no lint profile, so lint leaves its sources out; the profiles it
  # uses go to <build>/checks/lint-profiles.txt for the check to verify.
  list(REMOVE_DUPLICATES scope_lint)
  set(linted)
  set(profiles)
  foreach(source IN LISTS scope_lint)
    _telar_lint_profile("${source}" profile)
    if(profile)
      list(APPEND linted "${source}")
      list(APPEND profiles "${profile}")
    endif()
  endforeach()
  set(scope_lint ${linted})
  if(profiles)
    list(REMOVE_DUPLICATES profiles)
    list(SORT profiles)
    list(JOIN profiles "\n" content)
    file(CONFIGURE OUTPUT "${CMAKE_BINARY_DIR}/checks/lint-profiles.txt" CONTENT "${content}\n" @ONLY)
  endif()

  set(script "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/scripts/check.cmake")
  foreach(check IN LISTS TELAR_CHECKS)
    if(NOT scope_${check})
      continue()
    endif()
    list(REMOVE_DUPLICATES scope_${check})
    list(SORT scope_${check})
    list(JOIN scope_${check} "\n" content)
    file(CONFIGURE OUTPUT "${CMAKE_BINARY_DIR}/checks/${check}.txt" CONTENT "${content}\n" @ONLY)
    string(REPLACE "_" "-" name "${prefix}${check}")
    add_custom_target(${name}
      COMMAND "${CMAKE_COMMAND}" "-DCHECK=${check}" "-DBUILD_DIRECTORY=${CMAKE_BINARY_DIR}"
        "-DJOBS=${TELAR_CHECK_JOBS}" "-DTBC_LINTER=${TBC_LINTER}" -P "${script}"
      USES_TERMINAL
      VERBATIM)
  endforeach()
endfunction()

# Sets <out> to the .clang-tidy nearest the source within the project, or to nothing.
function(_telar_lint_profile source out)
  cmake_path(GET source PARENT_PATH directory)
  while(TRUE)
    if(EXISTS "${directory}/.clang-tidy")
      set(${out} "${directory}/.clang-tidy" PARENT_SCOPE)
      return()
    endif()
    if(directory STREQUAL CMAKE_SOURCE_DIR)
      break()
    endif()
    cmake_path(GET directory PARENT_PATH parent)
    cmake_path(IS_PREFIX CMAKE_SOURCE_DIR "${parent}" NORMALIZE inside)
    if(NOT inside OR parent STREQUAL directory)
      break()
    endif()
    set(directory "${parent}")
  endwhile()
  set(${out} "" PARENT_SCOPE)
endfunction()

# Sets <out> to the absolute paths of the target's sources and module interfaces that
# are in the repository rather than generated into the build tree.
function(_telar_check_sources target out)
  get_target_property(directory ${target} SOURCE_DIR)
  get_target_property(sources ${target} SOURCES)
  if(NOT sources)
    set(sources)
  endif()
  get_target_property(sets ${target} CXX_MODULE_SETS)
  foreach(set IN LISTS sets)
    if(set STREQUAL "CXX_MODULES")
      get_target_property(interfaces ${target} CXX_MODULE_SET)
    else()
      get_target_property(interfaces ${target} CXX_MODULE_SET_${set})
    endif()
    list(APPEND sources ${interfaces})
  endforeach()
  set(paths)
  foreach(source IN LISTS sources)
    if(source MATCHES "\\$<")
      continue()
    endif()
    cmake_path(ABSOLUTE_PATH source BASE_DIRECTORY "${directory}" NORMALIZE)
    cmake_path(IS_PREFIX CMAKE_BINARY_DIR "${source}" NORMALIZE generated)
    if(NOT generated)
      list(APPEND paths "${source}")
    endif()
  endforeach()
  set(${out} "${paths}" PARENT_SCOPE)
endfunction()
