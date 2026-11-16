include_guard(GLOBAL)

include("${CMAKE_CURRENT_LIST_DIR}/TelarBuild.cmake")

# How every telar library, domain and test is declared. A library or domain is a
# static archive whose module interfaces are every .cppm below its folder; a test
# builds beside the process it tests. Each helper registers its target for the
# quality checks of cmake/TelarChecks.cmake, which take their scope from here.

# The quality checks a target can register for.
set(TELAR_CHECKS lint lifetime blank_lines interface_bodies)

# telar_register_checks(<target> CHECKS <check>...): adds the target's sources to the
# scope of each check. The helpers call it; a target they do not create yet calls it
# itself.
function(telar_register_checks target)
  cmake_parse_arguments(PARSE_ARGV 1 register "" "" "CHECKS")
  foreach(check IN LISTS register_CHECKS)
    if(NOT check IN_LIST TELAR_CHECKS)
      message(FATAL_ERROR "${target}: unknown check '${check}'; the checks are ${TELAR_CHECKS}")
    endif()
  endforeach()
  set_property(TARGET ${target} APPEND PROPERTY TELAR_CHECKS ${register_CHECKS})
  set_property(GLOBAL APPEND PROPERTY TELAR_CHECK_TARGETS ${target})
endfunction()

# telar_modules(<target> [EXCLUDE <folder>...]): makes every module interface below
# the current folder part of the target's public module file set, so scanning,
# transitive ordering and installed consumers use CMake's native module graph.
# EXCLUDE names subfolders that build their modules into a target of their own.
function(telar_modules target)
  cmake_parse_arguments(PARSE_ARGV 1 modules "" "" "EXCLUDE")
  file(GLOB_RECURSE interfaces CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/*.cppm")
  list(FILTER interfaces EXCLUDE REGEX "/(tests|tools|vendor|out(-[^/]*)?|CMakeFiles)/")
  foreach(folder IN LISTS modules_EXCLUDE)
    foreach(source IN LISTS interfaces)
      string(FIND "${source}" "${CMAKE_CURRENT_SOURCE_DIR}/${folder}/" position)
      if(position EQUAL 0)
        list(REMOVE_ITEM interfaces "${source}")
      endif()
    endforeach()
  endforeach()
  include("${CMAKE_CURRENT_FUNCTION_LIST_DIR}/module_platforms.cmake")
  get_filename_component(repository "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/.." ABSOLUTE)
  if(APPLE)
    set(excluded ${TELAR_LINUX_MODULES})
  else()
    set(excluded ${TELAR_MACOS_MODULES})
  endif()
  foreach(source IN LISTS excluded)
    list(REMOVE_ITEM interfaces "${repository}/${source}")
  endforeach()
  if(NOT interfaces)
    message(FATAL_ERROR "No module interfaces for ${target}")
  endif()
  target_sources(${target} PUBLIC FILE_SET CXX_MODULES BASE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}" FILES ${interfaces})
  target_compile_features(${target} PUBLIC cxx_std_23)
  target_link_libraries(${target} PUBLIC telar::build_flags)
  set_target_properties(${target} PROPERTIES POSITION_INDEPENDENT_CODE ON)
endfunction()

# telar_add_library(<name> [ALIAS <alias>] [SOURCES <file>...] [EXCLUDE <folder>...]
#                   [INCLUDES <directory>...] [DEPS <target>...] [CHECKS <check>...])
# A static library of the module interfaces below the current folder and SOURCES, its
# implementation units. ALIAS defaults to telar::<x> for a name telar-<x>. INCLUDES are
# public include directories and DEPS public dependencies. CHECKS defaults to every check.
function(telar_add_library name)
  cmake_parse_arguments(PARSE_ARGV 1 library "" "ALIAS" "SOURCES;EXCLUDE;INCLUDES;DEPS;CHECKS")
  if(library_UNPARSED_ARGUMENTS)
    message(FATAL_ERROR "telar_add_library(${name}): unexpected arguments ${library_UNPARSED_ARGUMENTS}")
  endif()
  if(NOT library_ALIAS)
    if(NOT name MATCHES "^telar-(.+)$")
      message(FATAL_ERROR "telar_add_library(${name}): name an ALIAS for a target outside telar-*")
    endif()
    set(library_ALIAS "telar::${CMAKE_MATCH_1}")
  endif()
  if(NOT DEFINED library_CHECKS AND NOT "CHECKS" IN_LIST library_KEYWORDS_MISSING_VALUES)
    set(library_CHECKS ${TELAR_CHECKS})
  endif()

  add_library(${name} STATIC ${library_SOURCES})
  add_library(${library_ALIAS} ALIAS ${name})
  telar_modules(${name} EXCLUDE ${library_EXCLUDE})
  if(library_INCLUDES)
    target_include_directories(${name} PUBLIC ${library_INCLUDES})
  endif()
  if(library_DEPS)
    target_link_libraries(${name} PUBLIC ${library_DEPS})
  endif()
  telar_register_checks(${name} CHECKS ${library_CHECKS})
endfunction()

# telar_add_domain(<process> <domain> [SOURCES <file>...] [INCLUDES <directory>...]
#                  [DEPS <domain or target>...] [CHECKS <check>...])
# A domain of a process (docs/build/modules.json, process_layers) as the library
# <process>-<domain>, aliased telar::<process>::<domain>, from the folder whose
# CMakeLists.txt declares it. A plain name in DEPS is a domain of the same process.
function(telar_add_domain process domain)
  cmake_parse_arguments(PARSE_ARGV 2 domain "" "" "SOURCES;INCLUDES;DEPS;CHECKS")
  if(domain_UNPARSED_ARGUMENTS)
    message(FATAL_ERROR "telar_add_domain(${process} ${domain}): unexpected arguments ${domain_UNPARSED_ARGUMENTS}")
  endif()
  set(dependencies)
  foreach(dependency IN LISTS domain_DEPS)
    if(dependency MATCHES "^[a-z0-9_]+$")
      set(dependency "telar::${process}::${dependency}")
    endif()
    list(APPEND dependencies "${dependency}")
  endforeach()
  set(checks)
  if(DEFINED domain_CHECKS OR "CHECKS" IN_LIST domain_KEYWORDS_MISSING_VALUES)
    set(checks CHECKS ${domain_CHECKS})
  endif()
  telar_add_library(${process}-${domain} ALIAS telar::${process}::${domain}
    SOURCES ${domain_SOURCES}
    INCLUDES ${domain_INCLUDES}
    DEPS ${dependencies}
    ${checks})
endfunction()

# telar_add_test(<name> [QT | STATIC | SHARED] SOURCES <file>... [LIBRARIES <target>...]
#                [NO_TEST | PROBE] [TEST <test>] [ARGS <argument>...]
#                [LABELS <label>...] [TIMEOUT <seconds>] [ENVIRONMENT <variable=value>...]
#                [CHECKS <check>...])
# telar_add_test(<test> COMMAND <command>... LABELS <label>... [TIMEOUT ...] [ENVIRONMENT ...])
#
# With SOURCES, a test program <name> (qt_add_executable with QT), or with STATIC or
# SHARED a library for tests to link, whose .cppm sources are module interfaces. It
# builds into the process's build directory, where tools and tests find it beside the
# process. LIBRARIES are linked privately into a program and publicly into a library.
# CTest runs the program as TEST (default <name>) with ARGS, unless NO_TEST, or PROBE,
# a program run by hand that only the <process>-probes target builds. Without SOURCES
# it registers the test <test> that runs COMMAND. A test carries LABELS
# <process>.<domain>, so `ctest -L runtime.terminal` runs the tests of a domain.
# CHECKS defaults to lint and blank_lines.
function(telar_add_test name)
  cmake_parse_arguments(PARSE_ARGV 1 test "QT;STATIC;SHARED;NO_TEST;PROBE" "TEST;TIMEOUT"
    "SOURCES;LIBRARIES;ARGS;COMMAND;LABELS;ENVIRONMENT;CHECKS")
  if(test_UNPARSED_ARGUMENTS)
    message(FATAL_ERROR "telar_add_test(${name}): unexpected arguments ${test_UNPARSED_ARGUMENTS}")
  endif()
  if(NOT DEFINED test_CHECKS AND NOT "CHECKS" IN_LIST test_KEYWORDS_MISSING_VALUES)
    set(test_CHECKS lint blank_lines)
  endif()

  set(register OFF)
  if(test_SOURCES)
    if(test_STATIC OR test_SHARED)
      set(interfaces ${test_SOURCES})
      list(FILTER interfaces INCLUDE REGEX "\\.cppm$")
      set(sources ${test_SOURCES})
      list(FILTER sources EXCLUDE REGEX "\\.cppm$")
      if(test_STATIC)
        add_library(${name} STATIC ${sources})
      else()
        add_library(${name} SHARED ${sources})
      endif()
      if(interfaces)
        target_sources(${name} PUBLIC FILE_SET CXX_MODULES BASE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}" FILES ${interfaces})
        set_target_properties(${name} PROPERTIES POSITION_INDEPENDENT_CODE ON)
      endif()
      if(test_LIBRARIES AND test_STATIC)
        target_link_libraries(${name} PUBLIC ${test_LIBRARIES})
      elseif(test_LIBRARIES)
        target_link_libraries(${name} PRIVATE ${test_LIBRARIES})
      endif()
    else()
      if(test_QT)
        qt_add_executable(${name} ${test_SOURCES})
      else()
        add_executable(${name} ${test_SOURCES})
      endif()
      if(test_LIBRARIES)
        target_link_libraries(${name} PRIVATE ${test_LIBRARIES})
      endif()
      if(NOT test_NO_TEST AND NOT test_PROBE)
        set(register ON)
        if(NOT test_COMMAND)
          set(test_COMMAND ${name})
        endif()
      endif()
    endif()
    set_target_properties(${name} PROPERTIES
      RUNTIME_OUTPUT_DIRECTORY "${PROJECT_BINARY_DIR}"
      LIBRARY_OUTPUT_DIRECTORY "${PROJECT_BINARY_DIR}")
    if(test_PROBE)
      set_target_properties(${name} PROPERTIES EXCLUDE_FROM_ALL ON)
      set_property(DIRECTORY "${PROJECT_SOURCE_DIR}" APPEND PROPERTY TELAR_PROBES ${name})
    endif()
    telar_register_checks(${name} CHECKS ${test_CHECKS})
  elseif(test_COMMAND)
    set(register ON)
  else()
    message(FATAL_ERROR "telar_add_test(${name}): give SOURCES or COMMAND")
  endif()

  if(NOT register)
    return()
  endif()
  if(NOT test_LABELS)
    message(FATAL_ERROR "telar_add_test(${name}): a test needs LABELS <process>.<domain>")
  endif()
  if(NOT test_TEST)
    set(test_TEST ${name})
  endif()
  add_test(NAME ${test_TEST} COMMAND ${test_COMMAND} ${test_ARGS})
  set_tests_properties(${test_TEST} PROPERTIES LABELS "${test_LABELS}")
  if(test_TIMEOUT)
    set_tests_properties(${test_TEST} PROPERTIES TIMEOUT ${test_TIMEOUT})
  endif()
  if(test_ENVIRONMENT)
    set_tests_properties(${test_TEST} PROPERTIES ENVIRONMENT "${test_ENVIRONMENT}")
  endif()
endfunction()

# telar_add_probes(<target>): the target that builds every PROBE of this process.
function(telar_add_probes target)
  get_property(probes DIRECTORY "${PROJECT_SOURCE_DIR}" PROPERTY TELAR_PROBES)
  add_custom_target(${target} DEPENDS ${probes})
endfunction()
