option(CLIPBOARD_WARNINGS_AS_ERRORS "Treat compiler warnings as errors" OFF)
option(CLIPBOARD_LINUX_INTEGRATION_TESTS "Test private Sway and Xvfb clipboards" OFF)
# Static headless distribution builds must not acquire desktop dependencies.
if(TELAR_LINUX_DISTRIBUTABLE)
  option(TELAR_CLIPBOARD_NATIVE "Build native graphical-session clipboard access" OFF)
endif()
option(TELAR_CLIPBOARD_NATIVE "Build native graphical-session clipboard access" ON)

# telar.clipboard exports the API to C++ importers; the Linux backends are modules that own
# their libraries' headers, and the reader imports both.
add_library(telar-clipboard STATIC)
target_compile_features(telar-clipboard PUBLIC cxx_std_23)
target_include_directories(telar-clipboard PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_sources(telar-clipboard PUBLIC FILE_SET CXX_MODULES BASE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}"
  FILES "${CMAKE_CURRENT_SOURCE_DIR}/clipboard.cppm")
# The header-only tbc annotations state the API's lifetime contracts.
target_link_libraries(telar-clipboard PUBLIC tbc::tbc telar::sys)
if(NOT TELAR_CLIPBOARD_NATIVE)
  target_sources(telar-clipboard PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src/unavailable.cpp")
elseif(APPLE)
  enable_language(OBJCXX)
  include(CheckOBJCXXCompilerFlag)
  check_objcxx_compiler_flag(-fno-objc-msgsend-class-selector-stubs CLIPBOARD_HAS_OBJC_CLASS_STUB_CONTROL)
  if(CLIPBOARD_HAS_OBJC_CLASS_STUB_CONTROL)
    target_compile_options(telar-clipboard PUBLIC "$<$<COMPILE_LANGUAGE:OBJCXX>:-fno-objc-msgsend-class-selector-stubs>")
  endif()
  target_sources(telar-clipboard PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src/clipboard.mm")
  set_target_properties(telar-clipboard PROPERTIES OBJCXX_STANDARD 23 OBJCXX_STANDARD_REQUIRED YES OBJCXX_EXTENSIONS NO)
  target_compile_options(telar-clipboard PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
  target_link_libraries(telar-clipboard PUBLIC "-framework AppKit")
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
  target_sources(telar-clipboard PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src/linux/clipboard.cpp" "${CMAKE_CURRENT_SOURCE_DIR}/transfer/transfer.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/wayland/wayland.cpp" "${CMAKE_CURRENT_SOURCE_DIR}/x11/x11.cpp"
    "${clipboard_protocol_header}" "${clipboard_protocol_code}")
  target_sources(telar-clipboard PRIVATE FILE_SET clipboard_linux TYPE CXX_MODULES BASE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}"
    FILES "${CMAKE_CURRENT_SOURCE_DIR}/transfer/transfer.cppm" "${CMAKE_CURRENT_SOURCE_DIR}/wayland/wayland.cppm"
    "${CMAKE_CURRENT_SOURCE_DIR}/x11/x11.cppm")
  target_include_directories(telar-clipboard PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
  target_link_libraries(telar-clipboard PUBLIC PkgConfig::CLIPBOARD_LINUX)
else()
  message(FATAL_ERROR "Clipboard currently supports macOS and Linux")
endif()
target_compile_options(telar-clipboard PRIVATE ${TELAR_WARNINGS})
telar_register_checks(telar-clipboard CHECKS lint blank_lines)

# The standalone reader and its tests build with the other tests.
if(BUILD_TESTING)
  add_executable(clipboard main.cpp cli.cpp)
  target_link_libraries(clipboard PRIVATE telar-clipboard)
  target_compile_options(clipboard PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wshadow)
  set(clipboard_targets telar-clipboard clipboard)
  telar_register_checks(clipboard CHECKS lint lifetime)

  if(APPLE AND TELAR_CLIPBOARD_NATIVE)
    set(clipboard_test_support "${CMAKE_CURRENT_SOURCE_DIR}/../../src/gui/tests")
    add_executable(clipboard-test
      tests/clipboard_test.mm
      cli.cpp
      "${clipboard_test_support}/platform/macos/private_clipboard.mm"
    )
    target_include_directories(clipboard-test PRIVATE "${clipboard_test_support}")
    set_target_properties(clipboard-test PROPERTIES OBJCXX_STANDARD 23 OBJCXX_STANDARD_REQUIRED YES OBJCXX_EXTENSIONS NO)
    target_compile_options(clipboard-test PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>" -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wshadow)
    target_link_libraries(clipboard-test PRIVATE telar-clipboard)
    add_test(NAME clipboard-content COMMAND clipboard-test)
    set_tests_properties(clipboard-content PROPERTIES TIMEOUT 30 LABELS lib.clipboard)
    list(APPEND clipboard_targets clipboard-test)
  elseif(TELAR_CLIPBOARD_NATIVE AND CLIPBOARD_LINUX_INTEGRATION_TESTS AND CMAKE_SYSTEM_NAME STREQUAL "Linux")
    find_package(Python3 REQUIRED COMPONENTS Interpreter)
    foreach(tool IN ITEMS sway wl-copy wl-paste xvfb-run xauth xclip)
      find_program(clipboard_test_${tool} ${tool} REQUIRED)
    endforeach()
    foreach(backend IN ITEMS wayland x11)
      add_test(NAME clipboard-${backend}
        COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/tests/linux_clipboard_test.py"
          "$<TARGET_FILE:clipboard>" --backend ${backend})
      set_tests_properties(clipboard-${backend} PROPERTIES TIMEOUT 90 LABELS lib.clipboard)
    endforeach()
  endif()

  # -Werror goes on each source of these targets, not on the targets: CMake compiles the std
  # module of every importer with that importer's options, and Clang warns about the
  # toolchain's std.cppm (reserved module name, unused -stdlib).
  if(CLIPBOARD_WARNINGS_AS_ERRORS)
    set(clipboard_strict_sources)
    foreach(target IN LISTS clipboard_targets)
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
endif()
