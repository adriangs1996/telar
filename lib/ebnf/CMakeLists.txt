option(EBNF_WARNINGS_AS_ERRORS "Treat compiler warnings as errors" OFF)
option(EBNF_GOOGLETEST "Build the GoogleTest suite of the ebnf executable; configuring downloads GoogleTest" OFF)

# The interfaces keep function bodies and fail the lifetime analysis, so they are not yet
# checked for either.
telar_add_library(ebnf-core ALIAS ebnf::ebnf
  INCLUDES "${CMAKE_CURRENT_SOURCE_DIR}"
  DEPS telar::tbc
  CHECKS lint blank_lines)

# A consumer such as the GUI only needs the library. The ebnf executable and its tests
# build with the other tests.
if(NOT BUILD_TESTING)
  return()
endif()

add_library(ebnf_options INTERFACE)
target_include_directories(ebnf_options INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(ebnf_options INTERFACE tbc::tbc ebnf-core)
target_compile_options(ebnf_options INTERFACE -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wshadow)
if(EBNF_WARNINGS_AS_ERRORS)
  target_compile_options(ebnf_options INTERFACE -Werror)
endif()

# CONFIGURE_DEPENDS rechecks source additions and removals during each build.
file(GLOB_RECURSE ebnf_sources RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}" CONFIGURE_DEPENDS
  "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/*.cc"
  "${CMAKE_CURRENT_SOURCE_DIR}/*.cxx")
list(FILTER ebnf_sources EXCLUDE REGEX "(^|/)(out|build[^/]*|cmake-build[^/]*|\\.git|vendor|third_party|generated|_deps)/")
set(ebnf_test_sources ${ebnf_sources})
list(FILTER ebnf_test_sources INCLUDE REGEX "^tests/")
list(FILTER ebnf_sources EXCLUDE REGEX "^tests/")
list(REMOVE_ITEM ebnf_sources main.cpp)

add_executable(ebnf main.cpp ${ebnf_sources})
target_link_libraries(ebnf PRIVATE ebnf_options)
add_test(NAME ebnf-smoke COMMAND ebnf)
set_tests_properties(ebnf-smoke PROPERTIES TIMEOUT 30 LABELS lib.ebnf)
telar_register_checks(ebnf CHECKS lint lifetime)

if(EBNF_GOOGLETEST)
  include(cmake/tests.cmake)
  telar_register_checks(ebnf_tests CHECKS lint lifetime)
endif()
