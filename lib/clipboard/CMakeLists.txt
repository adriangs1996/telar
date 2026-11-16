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
option(CLIPBOARD_LINUX_INTEGRATION_TESTS "Test private Sway and Xvfb clipboards" OFF)

include(cmake/library.cmake)
add_executable(clipboard main.cpp cli.cpp)
target_link_libraries(clipboard PRIVATE telar-clipboard)

if(MSVC)
  target_compile_options(clipboard PRIVATE /W4 /permissive- /Zc:__cplusplus)
  if(CLIPBOARD_WARNINGS_AS_ERRORS)
    target_compile_options(clipboard PRIVATE /WX)
  endif()
elseif(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(telar-clipboard PUBLIC -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wshadow)
endif()

if(CLIPBOARD_SANITIZERS)
  if(MSVC OR NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    message(FATAL_ERROR "CLIPBOARD_SANITIZERS requires GCC or Clang with the GNU-style driver")
  endif()
  target_compile_options(telar-clipboard PUBLIC -fsanitize=address,undefined -fno-omit-frame-pointer)
  target_link_options(telar-clipboard PUBLIC -fsanitize=address,undefined)
endif()

include(CTest)
if(BUILD_TESTING)
  add_test(NAME clipboard-smoke COMMAND clipboard --help)
  set_tests_properties(clipboard-smoke PROPERTIES TIMEOUT 30)

  if(APPLE AND TELAR_CLIPBOARD_NATIVE)
    set(clipboard_test_support "${CMAKE_CURRENT_SOURCE_DIR}/../../src/gui/tests")
    add_executable(clipboard-test
      tests/clipboard_test.mm
      cli.cpp
      "${clipboard_test_support}/platform/macos/private_clipboard.mm"
    )
    target_include_directories(clipboard-test PRIVATE includes "${clipboard_test_support}")
    set_target_properties(clipboard-test PROPERTIES OBJCXX_STANDARD 23 OBJCXX_STANDARD_REQUIRED YES OBJCXX_EXTENSIONS NO)
    target_compile_options(clipboard-test PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>" -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wshadow)
    target_link_libraries(clipboard-test PRIVATE telar-clipboard)

    if(CLIPBOARD_SANITIZERS)
      target_compile_options(clipboard-test PRIVATE -fsanitize=address,undefined -fno-omit-frame-pointer)
      target_link_options(clipboard-test PRIVATE -fsanitize=address,undefined)
    endif()

    add_test(NAME clipboard-content COMMAND clipboard-test)
    set_tests_properties(clipboard-content PROPERTIES TIMEOUT 30)
  elseif(TELAR_CLIPBOARD_NATIVE AND CLIPBOARD_LINUX_INTEGRATION_TESTS AND CMAKE_SYSTEM_NAME STREQUAL "Linux")
    find_package(Python3 REQUIRED COMPONENTS Interpreter)
    foreach(tool IN ITEMS sway wl-copy wl-paste xvfb-run xauth xclip)
      find_program(clipboard_test_${tool} ${tool} REQUIRED)
    endforeach()
    foreach(backend IN ITEMS wayland x11)
      add_test(NAME clipboard-${backend}
        COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/tests/linux_clipboard_test.py"
          "$<TARGET_FILE:clipboard>" --backend ${backend})
      set_tests_properties(clipboard-${backend} PROPERTIES TIMEOUT 90)
    endforeach()
  endif()
endif()

# -Werror goes on each source of these targets, not on the targets: CMake compiles the std
# module of every importer with that importer's options, and Clang warns about the
# toolchain's std.cppm (reserved module name, unused -stdlib).
if(CLIPBOARD_WARNINGS_AS_ERRORS AND NOT MSVC)
  set(clipboard_strict_sources)
  foreach(target IN ITEMS telar-clipboard clipboard clipboard-test)
    if(NOT TARGET ${target})
      continue()
    endif()

    get_target_property(sources ${target} SOURCES)
    get_target_property(module_sets ${target} CXX_MODULE_SETS)
    list(APPEND clipboard_strict_sources ${sources})
    foreach(module_set IN LISTS module_sets)
      if(module_set STREQUAL "CXX_MODULES")
        get_target_property(modules ${target} CXX_MODULE_SET)
      else()
        get_target_property(modules ${target} CXX_MODULE_SET_${module_set})
      endif()
      list(APPEND clipboard_strict_sources ${modules})
    endforeach()
  endforeach()
  list(REMOVE_DUPLICATES clipboard_strict_sources)
  set_property(SOURCE ${clipboard_strict_sources} APPEND PROPERTY COMPILE_OPTIONS -Werror)
endif()

telar_checks()
telar_register_checks(clipboard CHECKS lint lifetime)
if(TARGET clipboard-test)
  telar_register_checks(clipboard-test CHECKS lint)
endif()
