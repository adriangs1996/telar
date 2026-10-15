cmake_minimum_required(VERSION 3.28)

include(cmake/compiler.cmake)
project(telar_desktop LANGUAGES CXX)

if(NOT CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
  message(FATAL_ERROR "Use upstream LLVM Clang with clang-scan-deps; set CXX or CMAKE_CXX_COMPILER")
endif()

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

find_package(Threads REQUIRED)
include(CTest)

# Source discovery is intentional: adding a module or a development program
# must not require editing the build definition.
file(GLOB_RECURSE desktop_modules RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}" CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/*.cppm")
file(GLOB_RECURSE desktop_sources RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}" CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp")
list(FILTER desktop_modules EXCLUDE REGEX "(^|/)(out|zig-out|\\.zig-cache|debug|tests)/")
list(FILTER desktop_sources EXCLUDE REGEX "(^|/)(out|zig-out|\\.zig-cache|debug|tests)/")
list(REMOVE_ITEM desktop_sources main.cpp)

add_library(desktop-core STATIC ${desktop_sources})
target_sources(desktop-core PUBLIC FILE_SET CXX_MODULES FILES ${desktop_modules})
target_include_directories(desktop-core PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(desktop-core PUBLIC Threads::Threads)
target_compile_definitions(desktop-core PUBLIC "$<$<CONFIG:Debug>:TELAR_DEBUG=1>")

add_executable(telar-desktop main.cpp)
target_link_libraries(telar-desktop PRIVATE desktop-core)

add_custom_target(desktop-editor DEPENDS desktop-core)

file(GLOB_RECURSE debug_support_modules CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/debug/support/*.cppm")
file(GLOB_RECURSE debug_support_sources CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/debug/support/*.cpp")

if(debug_support_modules OR debug_support_sources)
  add_library(desktop-debug-support STATIC ${debug_support_sources})
  if(debug_support_modules)
    target_sources(desktop-debug-support PUBLIC FILE_SET CXX_MODULES FILES ${debug_support_modules})
  endif()
  target_link_libraries(desktop-debug-support PUBLIC desktop-core)
  add_dependencies(desktop-editor desktop-debug-support)
else()
  add_library(desktop-debug-support INTERFACE)
  target_link_libraries(desktop-debug-support INTERFACE desktop-core)
endif()

file(GLOB_RECURSE desktop_programs CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/debug/*.cpp")
list(FILTER desktop_programs EXCLUDE REGEX "/debug/support/")
foreach(source IN LISTS desktop_programs)
  file(RELATIVE_PATH program "${CMAKE_CURRENT_SOURCE_DIR}/debug" "${source}")
  string(REGEX REPLACE "\\.cpp$" "" program "${program}")
  string(REPLACE "/" "-" program "${program}")
  add_executable("${program}" "${source}")
  target_link_libraries("${program}" PRIVATE desktop-debug-support)
  add_dependencies(desktop-editor "${program}")
endforeach()

if(BUILD_TESTING)
  add_executable(toolchain-check tests/toolchain.cpp)
  target_link_libraries(toolchain-check PRIVATE desktop-core)
  add_test(NAME desktop-toolchain COMMAND toolchain-check)
  set_tests_properties(desktop-toolchain PROPERTIES PASS_REGULAR_EXPRESSION "C\\+\\+23 generator and modules OK")
  add_dependencies(desktop-editor toolchain-check)
endif()
