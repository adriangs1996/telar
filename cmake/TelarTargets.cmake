include_guard(GLOBAL)

include("${CMAKE_CURRENT_LIST_DIR}/TelarBuild.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/TelarChecks.cmake")

# How every telar library, domain and test is declared. A library or domain is a
# static archive whose module interfaces are every .cppm below its folder; a test
# builds beside the process it tests. Each helper registers its target for the
# quality checks of cmake/TelarChecks.cmake, which take their scope from here.

# telar_process(<name> [OPTIONS <option>...] [QML <folder>]): the folder that calls it is
# the process <name>. Its source and binary directories become TELAR_PROCESS_SOURCE_DIR and
# TELAR_PROCESS_BINARY_DIR for the helpers called here and in the folders below, which
# build tests and probes beside the process. It creates <name>-settings, the INTERFACE
# target every domain of the process links: before declaring its domains, the process gives
# it the include directories, definitions and libraries they compile and link with. OPTIONS
# are the compile options of every domain and of everything that links one. QML is the
# folder below the process that holds its QML, which its Qt tests scan for QML imports.
function(telar_process name)
  cmake_parse_arguments(PARSE_ARGV 1 process "" "QML" "OPTIONS")
  if(process_UNPARSED_ARGUMENTS)
    message(FATAL_ERROR "telar_process(${name}): unexpected arguments ${process_UNPARSED_ARGUMENTS}")
  endif()
  set(TELAR_PROCESS "${name}" PARENT_SCOPE)
  set(TELAR_PROCESS_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}" PARENT_SCOPE)
  set(TELAR_PROCESS_BINARY_DIR "${CMAKE_CURRENT_BINARY_DIR}" PARENT_SCOPE)
  set(TELAR_PROCESS_OPTIONS "${process_OPTIONS}" PARENT_SCOPE)
  set(qml_directory)
  if(process_QML)
    cmake_path(ABSOLUTE_PATH process_QML BASE_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}" NORMALIZE
      OUTPUT_VARIABLE qml_directory)
  endif()
  set(TELAR_PROCESS_QML_DIR "${qml_directory}" PARENT_SCOPE)
  add_library(${name}-settings INTERFACE)
endfunction()

# telar_modules(<target> [EXCLUDE <folder>...] [MACOS_SOURCES <file>...]
#               [LINUX_SOURCES <file>...]): makes every module interface below the
# current folder part of the target's public module file set, so scanning, transitive
# ordering and installed consumers use CMake's native module graph. EXCLUDE names
# subfolders that build their modules into a target of their own. MACOS_SOURCES and
# LINUX_SOURCES are the files of one platform, interfaces among them: elsewhere their
# interfaces leave the module set, and on it their other files are added as sources.
function(telar_modules target)
  cmake_parse_arguments(PARSE_ARGV 1 modules "" "" "EXCLUDE;MACOS_SOURCES;LINUX_SOURCES")
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
  set(sources)
  foreach(platform IN ITEMS MACOS LINUX)
    if((platform STREQUAL "MACOS" AND APPLE) OR (platform STREQUAL "LINUX" AND CMAKE_SYSTEM_NAME STREQUAL "Linux"))
      set(current ON)
    else()
      set(current OFF)
    endif()
    foreach(source IN LISTS modules_${platform}_SOURCES)
      cmake_path(ABSOLUTE_PATH source BASE_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}" NORMALIZE)
      if(NOT source MATCHES "\\.cppm$")
        if(current)
          list(APPEND sources "${source}")
        endif()
      elseif(NOT source IN_LIST interfaces)
        message(FATAL_ERROR "${target}: ${source} is not a module interface below ${CMAKE_CURRENT_SOURCE_DIR}")
      elseif(NOT current)
        list(REMOVE_ITEM interfaces "${source}")
      endif()
    endforeach()
  endforeach()
  if(NOT interfaces)
    message(FATAL_ERROR "No module interfaces for ${target}")
  endif()
  target_sources(${target} PUBLIC FILE_SET CXX_MODULES BASE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}" FILES ${interfaces})
  if(sources)
    target_sources(${target} PRIVATE ${sources})
  endif()
  target_compile_features(${target} PUBLIC cxx_std_23)
  target_link_libraries(${target} PUBLIC telar::build_flags)
  set_target_properties(${target} PROPERTIES POSITION_INDEPENDENT_CODE ON)
endfunction()

# telar_add_library(<name> [ALIAS <alias>] [SOURCES <file>...] [MACOS_SOURCES <file>...]
#                   [LINUX_SOURCES <file>...] [EXCLUDE <folder>...] [INCLUDES <directory>...]
#                   [DEPS <target>...] [CHECKS <check>...])
# A static library of the module interfaces below the current folder and SOURCES, its
# implementation units; MACOS_SOURCES and LINUX_SOURCES are those of one platform, as in
# telar_modules. ALIAS defaults to telar::<x> for a name telar-<x>. INCLUDES are public
# include directories and DEPS public dependencies. CHECKS defaults to every check.
function(telar_add_library name)
  cmake_parse_arguments(PARSE_ARGV 1 library "" "ALIAS" "SOURCES;MACOS_SOURCES;LINUX_SOURCES;EXCLUDE;INCLUDES;DEPS;CHECKS")
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
  telar_modules(${name} EXCLUDE ${library_EXCLUDE}
    MACOS_SOURCES ${library_MACOS_SOURCES} LINUX_SOURCES ${library_LINUX_SOURCES})
  if(library_INCLUDES)
    target_include_directories(${name} PUBLIC ${library_INCLUDES})
  endif()
  if(library_DEPS)
    target_link_libraries(${name} PUBLIC ${library_DEPS})
  endif()
  telar_register_checks(${name} CHECKS ${library_CHECKS})
endfunction()

# telar_add_domain(<process> <domain> [SOURCES <file>...] [MACOS_SOURCES <file>...]
#                  [LINUX_SOURCES <file>...] [INCLUDES <directory>...]
#                  [DEPS <domain or target>...] [CHECKS <check>...])
# A domain of a process (docs/build/modules.json, process_layers) as the library
# <process>-<domain>, aliased telar::<process>::<domain>, from the folder whose
# CMakeLists.txt declares it, below the folder of telar_process(<process>). It links
# <process>-settings. A plain name in DEPS is a domain of the same process, and
# tools/check-cpp-modules.py checks those against the domain's imports.
function(telar_add_domain process domain)
  cmake_parse_arguments(PARSE_ARGV 2 domain "" "" "SOURCES;MACOS_SOURCES;LINUX_SOURCES;INCLUDES;DEPS;CHECKS")
  if(domain_UNPARSED_ARGUMENTS)
    message(FATAL_ERROR "telar_add_domain(${process} ${domain}): unexpected arguments ${domain_UNPARSED_ARGUMENTS}")
  endif()
  if(NOT process STREQUAL TELAR_PROCESS)
    message(FATAL_ERROR "telar_add_domain(${process} ${domain}): declare it below the folder of telar_process(${process})")
  endif()
  # CMake compiles the interfaces a target imports again with the target's flags when they
  # differ (the GUI's -ffp-contract=off), but only those of the libraries the target links
  # itself, not those an INTERFACE library brings. So the domain links the libraries of
  # <process>-settings directly as well, and passes them on to its importers.
  get_target_property(libraries ${process}-settings INTERFACE_LINK_LIBRARIES)
  set(dependencies ${process}-settings)
  if(libraries)
    list(APPEND dependencies ${libraries})
  endif()
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
    MACOS_SOURCES ${domain_MACOS_SOURCES}
    LINUX_SOURCES ${domain_LINUX_SOURCES}
    INCLUDES ${domain_INCLUDES}
    DEPS ${dependencies}
    ${checks})
  # The process's options are the domain's own, so they come before those of the targets
  # it links (telar::build_flags), in its sources and in those of its importers.
  target_compile_options(${process}-${domain} PUBLIC ${TELAR_PROCESS_OPTIONS})
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
# process, and a test runs there. LIBRARIES are linked privately into a program and
# publicly into a library.
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
        # Static Qt links the QML plugins a program imports. Like the process's own programs,
        # a test scans the process's QML and finds its QML modules in its build directory.
        # The scan walks only the QML folder: a build tree left in the process's folder
        # would add its copies of the QML to every test's configure.
        set_target_properties(${name} PROPERTIES
          QT_QML_IMPORT_SCANNER_EXTRA_ROOT_PATHS "${TELAR_PROCESS_QML_DIR}"
          QT_QML_IMPORT_PATH "${TELAR_PROCESS_BINARY_DIR}")
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
      RUNTIME_OUTPUT_DIRECTORY "${TELAR_PROCESS_BINARY_DIR}"
      LIBRARY_OUTPUT_DIRECTORY "${TELAR_PROCESS_BINARY_DIR}"
      ARCHIVE_OUTPUT_DIRECTORY "${TELAR_PROCESS_BINARY_DIR}")
    if(test_PROBE)
      set_target_properties(${name} PROPERTIES EXCLUDE_FROM_ALL ON)
      set_property(DIRECTORY "${TELAR_PROCESS_SOURCE_DIR}" APPEND PROPERTY TELAR_PROBES ${name})
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
  add_test(NAME ${test_TEST} COMMAND ${test_COMMAND} ${test_ARGS} WORKING_DIRECTORY "${TELAR_PROCESS_BINARY_DIR}")
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
  get_property(probes DIRECTORY "${TELAR_PROCESS_SOURCE_DIR}" PROPERTY TELAR_PROBES)
  add_custom_target(${target} DEPENDS ${probes})
endfunction()

# telar_add_qml_sources(<target> [SOURCES <file>...] [QML_FILES <file>...]
#                       [FP_CONTRACT_OFF <file>...] [REGISTERS])
# Adds the files of the current folder to <target>, whose QML module an ancestor folder
# defines. SOURCES are its C++ sources and headers; FP_CONTRACT_OFF, some of them, compile
# with -ffp-contract=off. REGISTERS puts the folder on the target's include path, where
# the generated QML type registration finds each registered header by its bare name.
# QML_FILES are appended to the target's TELAR_QML_FILES, relative to the target's folder,
# for the ancestor to pass to qt_add_qml_module once every folder is added: the module
# keeps one resource and each file the resource path it has from the target's folder.
function(telar_add_qml_sources target)
  cmake_parse_arguments(PARSE_ARGV 1 qml "REGISTERS" "" "SOURCES;QML_FILES;FP_CONTRACT_OFF")
  if(qml_UNPARSED_ARGUMENTS)
    message(FATAL_ERROR "telar_add_qml_sources(${target}): unexpected arguments ${qml_UNPARSED_ARGUMENTS}")
  endif()
  if(qml_SOURCES)
    target_sources(${target} PRIVATE ${qml_SOURCES})
  endif()
  # Source properties belong to a directory: the target's is where its sources compile.
  if(qml_FP_CONTRACT_OFF)
    set_source_files_properties(${qml_FP_CONTRACT_OFF} TARGET_DIRECTORY ${target}
      PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
  endif()
  if(qml_REGISTERS)
    target_include_directories(${target} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
  endif()
  get_target_property(directory ${target} SOURCE_DIR)
  foreach(file IN LISTS qml_QML_FILES)
    cmake_path(ABSOLUTE_PATH file BASE_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}" NORMALIZE)
    cmake_path(RELATIVE_PATH file BASE_DIRECTORY "${directory}")
    set_property(TARGET ${target} APPEND PROPERTY TELAR_QML_FILES "${file}")
  endforeach()
endfunction()
