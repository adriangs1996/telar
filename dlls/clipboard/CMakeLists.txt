cmake_minimum_required(VERSION 3.25)

# Standalone LLVM tools need the SDK in the compilation database on macOS.
if(CMAKE_HOST_APPLE AND (NOT CMAKE_SYSTEM_NAME OR CMAKE_SYSTEM_NAME STREQUAL "Darwin"))
  if(NOT DEFINED CMAKE_OSX_SYSROOT AND NOT DEFINED ENV{SDKROOT})
    execute_process(COMMAND xcrun --sdk macosx --show-sdk-path
      OUTPUT_VARIABLE clipboard_macos_sdk OUTPUT_STRIP_TRAILING_WHITESPACE
      COMMAND_ERROR_IS_FATAL ANY)
    set(CMAKE_OSX_SYSROOT "${clipboard_macos_sdk}" CACHE PATH "macOS SDK")
  endif()
endif()

project(clipboard VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(CLIPBOARD_WARNINGS_AS_ERRORS "Treat compiler warnings as errors" OFF)
option(CLIPBOARD_SANITIZERS "Enable AddressSanitizer and UndefinedBehaviorSanitizer" OFF)

add_executable(clipboard main.cpp)
target_include_directories(clipboard PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/includes")

if(APPLE)
  if(NOT DEFINED CMAKE_OBJCXX_COMPILER)
    set(CMAKE_OBJCXX_COMPILER "${CMAKE_CXX_COMPILER}")
  endif()

  enable_language(OBJCXX)

  set_target_properties(
    clipboard PROPERTIES
    OBJCXX_STANDARD 23
    OBJCXX_STANDARD_REQUIRED YES
    OBJCXX_EXTENSIONS NO
  )

  find_library(APPKIT_FRAMEWORK AppKit REQUIRED)

  target_sources(clipboard PRIVATE src/clipboard.mm)
  target_compile_options(clipboard PRIVATE
       "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
     )
  target_link_libraries(clipboard PRIVATE "${APPKIT_FRAMEWORK}")
endif()

if(MSVC)
  target_compile_options(clipboard PRIVATE /W4 /permissive- /Zc:__cplusplus)
  if(CLIPBOARD_WARNINGS_AS_ERRORS)
    target_compile_options(clipboard PRIVATE /WX)
  endif()
elseif(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(clipboard PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wshadow)
  if(CLIPBOARD_WARNINGS_AS_ERRORS)
    target_compile_options(clipboard PRIVATE -Werror)
  endif()
endif()

if(CLIPBOARD_SANITIZERS)
  if(MSVC OR NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    message(FATAL_ERROR "CLIPBOARD_SANITIZERS requires GCC or Clang with the GNU-style driver")
  endif()
  target_compile_options(clipboard PRIVATE -fsanitize=address,undefined -fno-omit-frame-pointer)
  target_link_options(clipboard PRIVATE -fsanitize=address,undefined)
endif()

include(CTest)
if(BUILD_TESTING)
  add_test(NAME clipboard-smoke COMMAND clipboard)
  set_tests_properties(clipboard-smoke PROPERTIES TIMEOUT 30)
endif()

include("${CMAKE_CURRENT_SOURCE_DIR}/../tbc/cmake/tbcLifetimeCheck.cmake")
tbc_add_lifetime_check(lifetime-check "${CMAKE_CURRENT_SOURCE_DIR}/main.cpp")

get_filename_component(clipboard_compiler_directory "${CMAKE_CXX_COMPILER}" DIRECTORY)
foreach(mode IN ITEMS format format-check lint)
  add_custom_target(${mode}
    COMMAND "${CMAKE_COMMAND}"
      "-DMODE=${mode}"
      "-DSOURCE_DIR=${CMAKE_CURRENT_SOURCE_DIR}"
      "-DBINARY_DIR=${CMAKE_CURRENT_BINARY_DIR}"
      "-DCOMPILER_DIR=${clipboard_compiler_directory}"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/../ebnf/cmake/tooling.cmake"
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    USES_TERMINAL
    VERBATIM)
endforeach()
