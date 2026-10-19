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
find_package(PkgConfig REQUIRED)
pkg_check_modules(LUAJIT REQUIRED IMPORTED_TARGET luajit>=2.1)
find_package(Qt6 6.5 REQUIRED COMPONENTS Qml Quick QuickControls2)

# Source discovery is intentional: adding a module or a development program
# must not require editing the build definition.
file(GLOB_RECURSE desktop_modules RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}" CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/*.cppm")
file(GLOB_RECURSE desktop_sources RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}" CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp")
list(FILTER desktop_modules EXCLUDE REGEX "(^|/)(out|zig-out|\\.zig-cache|debug|tests)/")
list(FILTER desktop_sources EXCLUDE REGEX "(^|/)(out|zig-out|\\.zig-cache|debug|tests)/")
list(FILTER desktop_modules EXCLUDE REGEX "^ui/")
list(FILTER desktop_sources EXCLUDE REGEX "^ui/")
list(REMOVE_ITEM desktop_sources main.cpp)

add_library(desktop-core STATIC ${desktop_sources})
target_sources(desktop-core PUBLIC FILE_SET CXX_MODULES FILES ${desktop_modules})
target_include_directories(desktop-core PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(desktop-core PUBLIC Threads::Threads)
target_link_libraries(desktop-core PRIVATE PkgConfig::LUAJIT)
target_compile_definitions(desktop-core PUBLIC "$<$<CONFIG:Debug>:TELAR_DEBUG=1>")

file(GLOB_RECURSE desktop_ui_sources CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/ui/*.cpp")
add_library(desktop-ui STATIC ${desktop_ui_sources})
target_include_directories(desktop-ui PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(desktop-ui PUBLIC Qt6::Qml Qt6::Quick Qt6::QuickControls2)
target_link_libraries(desktop-ui PRIVATE PkgConfig::LUAJIT)

add_executable(telar-desktop main.cpp)

file(GLOB_RECURSE desktop_ui_scripts CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/ui/*.lua")
if(desktop_ui_scripts)
  qt_add_resources(telar-desktop desktop_ui_scripts
    PREFIX "/telar/ui"
    BASE "${CMAKE_CURRENT_SOURCE_DIR}/ui"
    FILES ${desktop_ui_scripts}
  )
endif()

if(APPLE)
  set(CMAKE_OBJCXX_COMPILER "${CMAKE_CXX_COMPILER}")
  enable_language(OBJCXX)
  set(CMAKE_OBJCXX_STANDARD 23)
  set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
  set(CMAKE_OBJCXX_EXTENSIONS OFF)

  find_library(APPKIT_FRAMEWORK AppKit REQUIRED)
  file(GLOB_RECURSE desktop_native_sources CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/native-backends/macos/*.mm")
  add_library(desktop-native OBJECT ${desktop_native_sources})
  target_compile_options(desktop-native PRIVATE -fobjc-arc)

  # Recent LLVM class-selector stubs require a newer Apple linker.
  include(CheckCompilerFlag)
  check_compiler_flag(OBJCXX "-fno-objc-msgsend-class-selector-stubs" desktop_has_class_selector_stub_flag)
  if(desktop_has_class_selector_stub_flag)
    target_compile_options(desktop-native PRIVATE -fno-objc-msgsend-class-selector-stubs)
  endif()

  target_link_libraries(desktop-native PUBLIC "${APPKIT_FRAMEWORK}")
  target_link_libraries(desktop-native PUBLIC desktop-ui)
  target_link_libraries(telar-desktop PRIVATE desktop-native)
endif()

target_link_libraries(telar-desktop PRIVATE desktop-core desktop-ui)

add_custom_target(desktop-editor DEPENDS desktop-core desktop-ui)

if(TARGET desktop-native)
  add_dependencies(desktop-editor desktop-native)
endif()

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
