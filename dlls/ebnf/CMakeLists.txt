cmake_minimum_required(VERSION 4.4.5)

# Export the SDK path so standalone LLVM tools can resolve Apple's C++ headers.
if(CMAKE_HOST_APPLE AND (NOT CMAKE_SYSTEM_NAME OR CMAKE_SYSTEM_NAME STREQUAL "Darwin"))
  if(NOT DEFINED CMAKE_OSX_SYSROOT AND NOT DEFINED ENV{SDKROOT})
    execute_process(COMMAND xcrun --sdk macosx --show-sdk-path
      OUTPUT_VARIABLE ebnf_macos_sdk OUTPUT_STRIP_TRAILING_WHITESPACE
      COMMAND_ERROR_IS_FATAL ANY)
    set(CMAKE_OSX_SYSROOT "${ebnf_macos_sdk}" CACHE PATH "macOS SDK")
  endif()
endif()

project(ebnf VERSION 0.1.0 LANGUAGES CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/cpp_modules.cmake")

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(EBNF_WARNINGS_AS_ERRORS "Treat compiler warnings as errors" OFF)
option(EBNF_SANITIZERS "Enable AddressSanitizer and UndefinedBehaviorSanitizer" OFF)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../tbc" "${CMAKE_CURRENT_BINARY_DIR}/tbc")

add_library(ebnf-core STATIC)
add_library(ebnf::ebnf ALIAS ebnf-core)
telar_modules(ebnf-core)
target_link_libraries(ebnf-core PUBLIC tbc::tbc)
target_include_directories(ebnf-core PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")

add_library(ebnf_options INTERFACE)
target_include_directories(ebnf_options INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(ebnf_options INTERFACE tbc::tbc ebnf-core)

# CONFIGURE_DEPENDS rechecks source additions and removals during each build.
file(GLOB_RECURSE ebnf_sources RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}" CONFIGURE_DEPENDS
  "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/*.cc"
  "${CMAKE_CURRENT_SOURCE_DIR}/*.cxx")
list(FILTER ebnf_sources EXCLUDE REGEX "(^|/)(out|build[^/]*|cmake-build[^/]*|\\.git|vendor|third_party|generated|_deps)/")
foreach(source IN LISTS ebnf_sources)
  set(source_path "${CMAKE_CURRENT_SOURCE_DIR}/${source}")
  cmake_path(IS_PREFIX CMAKE_CURRENT_BINARY_DIR "${source_path}" NORMALIZE in_build_directory)
  if(in_build_directory)
    list(REMOVE_ITEM ebnf_sources "${source}")
  endif()
endforeach()

set(ebnf_test_sources ${ebnf_sources})
list(FILTER ebnf_test_sources INCLUDE REGEX "^tests/")
list(FILTER ebnf_sources EXCLUDE REGEX "^tests/")
list(REMOVE_ITEM ebnf_sources main.cpp)

add_executable(ebnf main.cpp ${ebnf_sources})
target_link_libraries(ebnf PRIVATE ebnf_options)

if(MSVC)
  target_compile_options(ebnf_options INTERFACE /W4 /permissive- /Zc:__cplusplus)
  if(EBNF_WARNINGS_AS_ERRORS)
    target_compile_options(ebnf_options INTERFACE /WX)
  endif()
elseif(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(ebnf_options INTERFACE -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wshadow)
  if(EBNF_WARNINGS_AS_ERRORS)
    target_compile_options(ebnf_options INTERFACE -Werror)
  endif()
endif()

if(EBNF_SANITIZERS)
  if(MSVC OR NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    message(FATAL_ERROR "EBNF_SANITIZERS requires GCC or Clang with the GNU-style driver")
  endif()
  target_compile_options(ebnf_options INTERFACE -fsanitize=address,undefined -fno-omit-frame-pointer)
  target_link_options(ebnf_options INTERFACE -fsanitize=address,undefined)
endif()

include(CTest)
if(BUILD_TESTING)
  add_test(NAME ebnf-smoke COMMAND ebnf)
  set_tests_properties(ebnf-smoke PROPERTIES TIMEOUT 30)
  include(cmake/tests.cmake)
endif()

# Test translation units can instantiate templates with test doubles, so their diagnostics stay separate.
set(ebnf_lifetime_sources "${CMAKE_CURRENT_SOURCE_DIR}/main.cpp")
foreach(source IN LISTS ebnf_sources)
  list(APPEND ebnf_lifetime_sources "${CMAKE_CURRENT_SOURCE_DIR}/${source}")
endforeach()
tbc_add_lifetime_check(lifetime-check ${ebnf_lifetime_sources})

if(BUILD_TESTING)
  set(ebnf_test_lifetime_sources)
  foreach(source IN LISTS ebnf_test_sources)
    list(APPEND ebnf_test_lifetime_sources "${CMAKE_CURRENT_SOURCE_DIR}/${source}")
  endforeach()
  tbc_add_lifetime_check(lifetime-check-tests ${ebnf_test_lifetime_sources})
endif()

get_filename_component(ebnf_compiler_directory "${CMAKE_CXX_COMPILER}" DIRECTORY)
foreach(mode IN ITEMS format format-check lint)
  add_custom_target(${mode}
    COMMAND "${CMAKE_COMMAND}"
      "-DMODE=${mode}"
      "-DSOURCE_DIR=${CMAKE_CURRENT_SOURCE_DIR}"
      "-DBINARY_DIR=${CMAKE_CURRENT_BINARY_DIR}"
      "-DCOMPILER_DIR=${ebnf_compiler_directory}"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/tooling.cmake"
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    USES_TERMINAL
    VERBATIM)
endforeach()
