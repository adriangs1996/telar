cmake_minimum_required(VERSION 3.25)

# Standalone LLVM tools need the SDK in the compilation database on macOS.
if(CMAKE_HOST_APPLE AND (NOT CMAKE_SYSTEM_NAME OR CMAKE_SYSTEM_NAME STREQUAL "Darwin"))
  if(NOT DEFINED CMAKE_OSX_SYSROOT AND NOT DEFINED ENV{SDKROOT})
    execute_process(COMMAND xcrun --sdk macosx --show-sdk-path
      OUTPUT_VARIABLE tbc_macos_sdk OUTPUT_STRIP_TRAILING_WHITESPACE
      COMMAND_ERROR_IS_FATAL ANY)
    set(CMAKE_OSX_SYSROOT "${tbc_macos_sdk}" CACHE PATH "macOS SDK")
  endif()
endif()

project(tbc VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(TBC_BUILD_LINTER "Build the Clang AST lifetime linter" ${PROJECT_IS_TOP_LEVEL})
option(TBC_BUILD_EXAMPLE "Build the lifetime annotation example" ${PROJECT_IS_TOP_LEVEL})
option(TBC_WARNINGS_AS_ERRORS "Treat compiler warnings as errors" OFF)
option(TBC_SANITIZERS "Enable AddressSanitizer and UndefinedBehaviorSanitizer" OFF)

add_library(tbc INTERFACE)
add_library(tbc::tbc ALIAS tbc)
target_compile_features(tbc INTERFACE cxx_std_23)
target_include_directories(tbc INTERFACE
  "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>"
  "$<INSTALL_INTERFACE:include>")

# Project warnings and instrumentation must not propagate to library consumers.
add_library(tbc_options INTERFACE)
if(MSVC)
  target_compile_options(tbc_options INTERFACE /W4 /permissive- /Zc:__cplusplus)
  if(TBC_WARNINGS_AS_ERRORS)
    target_compile_options(tbc_options INTERFACE /WX)
  endif()
elseif(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(tbc_options INTERFACE -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wshadow)
  if(TBC_WARNINGS_AS_ERRORS)
    target_compile_options(tbc_options INTERFACE -Werror)
  endif()
endif()

if(TBC_SANITIZERS)
  if(MSVC OR NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    message(FATAL_ERROR "TBC_SANITIZERS requires GCC or Clang with the GNU-style driver")
  endif()
  target_compile_options(tbc_options INTERFACE -fsanitize=address,undefined -fno-omit-frame-pointer)
  target_link_options(tbc_options INTERFACE -fsanitize=address,undefined)
endif()

if(TBC_BUILD_EXAMPLE)
  add_executable(tbc-example main.cpp)
  target_link_libraries(tbc-example PRIVATE tbc::tbc tbc_options)
endif()

if(TBC_BUILD_LINTER)
  include(cmake/linter.cmake)
endif()

if(PROJECT_IS_TOP_LEVEL)
  include(CTest)
  if(BUILD_TESTING)
    include(cmake/tests.cmake)
  endif()
endif()

if(PROJECT_IS_TOP_LEVEL)
  get_filename_component(tbc_compiler_directory "${CMAKE_CXX_COMPILER}" DIRECTORY)
  foreach(mode IN ITEMS format format-check lint)
    add_custom_target(${mode}
      COMMAND "${CMAKE_COMMAND}"
        "-DMODE=${mode}"
        "-DSOURCE_DIR=${CMAKE_CURRENT_SOURCE_DIR}"
        "-DBINARY_DIR=${CMAKE_CURRENT_BINARY_DIR}"
        "-DCOMPILER_DIR=${tbc_compiler_directory}"
        -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/tooling.cmake"
      WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
      USES_TERMINAL
      VERBATIM)
  endforeach()
endif()

include(cmake/tbcLifetimeCheck.cmake)
if(TBC_BUILD_LINTER AND TBC_BUILD_EXAMPLE)
  tbc_add_lifetime_check(lifetime-check "${CMAKE_CURRENT_SOURCE_DIR}/main.cpp")
endif()

include(GNUInstallDirs)
include(CMakePackageConfigHelpers)
install(TARGETS tbc EXPORT tbcTargets)
if(TBC_BUILD_LINTER)
  install(TARGETS tbc-lint RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}")
endif()
install(DIRECTORY include/ DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}")
install(EXPORT tbcTargets NAMESPACE tbc:: DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/tbc")
configure_package_config_file(cmake/tbcConfig.cmake.in "${CMAKE_CURRENT_BINARY_DIR}/tbcConfig.cmake"
  INSTALL_DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/tbc")
write_basic_package_version_file("${CMAKE_CURRENT_BINARY_DIR}/tbcConfigVersion.cmake"
  COMPATIBILITY SameMajorVersion)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/tbcConfig.cmake" "${CMAKE_CURRENT_BINARY_DIR}/tbcConfigVersion.cmake" "${CMAKE_CURRENT_SOURCE_DIR}/cmake/tbcLifetimeCheck.cmake"
  DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/tbc")
