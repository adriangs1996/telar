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
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  enable_language(C)
  find_package(PkgConfig REQUIRED)
  pkg_check_modules(CLIPBOARD_LINUX REQUIRED IMPORTED_TARGET wayland-client xcb)
  find_program(WAYLAND_SCANNER wayland-scanner REQUIRED)
  set(clipboard_protocol "${CMAKE_CURRENT_SOURCE_DIR}/protocols/wlr-data-control-unstable-v1.xml")
  set(clipboard_protocol_header "${CMAKE_CURRENT_BINARY_DIR}/wlr-data-control-client-protocol.h")
  set(clipboard_protocol_code "${CMAKE_CURRENT_BINARY_DIR}/wlr-data-control-protocol.c")
  add_custom_command(OUTPUT "${clipboard_protocol_header}"
    COMMAND "${WAYLAND_SCANNER}" client-header "${clipboard_protocol}" "${clipboard_protocol_header}"
    DEPENDS "${clipboard_protocol}" VERBATIM)
  add_custom_command(OUTPUT "${clipboard_protocol_code}"
    COMMAND "${WAYLAND_SCANNER}" private-code "${clipboard_protocol}" "${clipboard_protocol_code}"
    DEPENDS "${clipboard_protocol}" VERBATIM)
  target_sources(clipboard PRIVATE
    src/linux/clipboard.cpp src/linux/wayland.cpp src/linux/x11.cpp
    "${clipboard_protocol_header}" "${clipboard_protocol_code}")
  target_include_directories(clipboard PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
  target_link_libraries(clipboard PRIVATE PkgConfig::CLIPBOARD_LINUX)
else()
  message(FATAL_ERROR "Clipboard currently supports macOS and Linux")
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
  add_test(NAME clipboard-smoke COMMAND clipboard --help)
  set_tests_properties(clipboard-smoke PROPERTIES TIMEOUT 30)

  if(APPLE)
    set(clipboard_test_support "${CMAKE_CURRENT_SOURCE_DIR}/../../services/gui-cpp/tests")
    add_executable(clipboard-test
      tests/clipboard_test.mm
      src/clipboard.mm
      "${clipboard_test_support}/platform/macos/private_clipboard.mm"
    )
    target_include_directories(clipboard-test PRIVATE includes "${clipboard_test_support}")
    set_target_properties(clipboard-test PROPERTIES OBJCXX_STANDARD 23 OBJCXX_STANDARD_REQUIRED YES OBJCXX_EXTENSIONS NO)
    target_compile_options(clipboard-test PRIVATE -fobjc-arc -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wshadow)
    target_link_libraries(clipboard-test PRIVATE "${APPKIT_FRAMEWORK}")

    if(CLIPBOARD_WARNINGS_AS_ERRORS)
      target_compile_options(clipboard-test PRIVATE -Werror)
    endif()

    if(CLIPBOARD_SANITIZERS)
      target_compile_options(clipboard-test PRIVATE -fsanitize=address,undefined -fno-omit-frame-pointer)
      target_link_options(clipboard-test PRIVATE -fsanitize=address,undefined)
    endif()

    add_test(NAME clipboard-content COMMAND clipboard-test)
    set_tests_properties(clipboard-content PROPERTIES TIMEOUT 30)
  elseif(CLIPBOARD_LINUX_INTEGRATION_TESTS AND CMAKE_SYSTEM_NAME STREQUAL "Linux")
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
