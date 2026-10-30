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
# The keyboard router uses Qt's platform interface on purpose.
set(QT_NO_PRIVATE_MODULE_WARNING ON)
find_package(Qt6 6.7 REQUIRED COMPONENTS Gui GuiPrivate Qml Quick QuickControls2 QuickShapes Network Concurrent)

# Debug builds trace every session to its own log file. Release builds compile debug and info
# traces out entirely.
add_compile_definitions(
  "$<$<CONFIG:Debug>:TELAR_DEBUG=1>"
  "$<$<NOT:$<CONFIG:Debug>>:QT_NO_DEBUG_OUTPUT>"
  "$<$<NOT:$<CONFIG:Debug>>:QT_NO_INFO_OUTPUT>"
)

# The keybinding engine uses only the C++ standard library.
file(GLOB keybindings_sources CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/keybindings-engine/*.cpp")
add_library(keybindings-engine STATIC ${keybindings_sources})
target_include_directories(keybindings-engine PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_compile_features(keybindings-engine PUBLIC cxx_std_23)

# Source discovery is intentional: adding a module or a development program
# must not require editing the build definition.
file(GLOB_RECURSE desktop_modules RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}" CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/*.cppm")
file(GLOB_RECURSE desktop_sources RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}" CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp")
list(FILTER desktop_modules EXCLUDE REGEX "(^|/)(out|zig-out|\\.zig-cache|debug|tests)/")
list(FILTER desktop_sources EXCLUDE REGEX "(^|/)(out|zig-out|\\.zig-cache|debug|tests)/")
list(FILTER desktop_modules EXCLUDE REGEX "^ui/")
list(FILTER desktop_sources EXCLUDE REGEX "^ui/")
list(FILTER desktop_sources EXCLUDE REGEX "^keybindings-engine/")
list(FILTER desktop_sources EXCLUDE REGEX "^native-backends/")
list(REMOVE_ITEM desktop_sources main.cpp)

add_library(desktop-core STATIC ${desktop_sources})
target_sources(desktop-core PUBLIC FILE_SET CXX_MODULES FILES ${desktop_modules})
target_include_directories(desktop-core PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(desktop-core PUBLIC Threads::Threads)
target_link_libraries(desktop-core PRIVATE Qt6::Core)
target_link_libraries(desktop-core PRIVATE PkgConfig::LUAJIT)
target_link_libraries(desktop-core PUBLIC keybindings-engine)

file(GLOB_RECURSE desktop_ui_sources CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/ui/*.cpp")
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  list(FILTER desktop_ui_sources EXCLUDE REGEX "/workbench/keyboard_router\.cpp$")
endif()
add_library(desktop-ui STATIC ${desktop_ui_sources})
target_include_directories(desktop-ui PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(desktop-ui PUBLIC Qt6::Qml Qt6::Quick Qt6::QuickControls2)
# The keyboard router sets Qt's focus window through the platform interface.
target_link_libraries(desktop-ui PRIVATE desktop-core PkgConfig::LUAJIT Qt6::GuiPrivate Qt6::QuickShapes Qt6::Network Qt6::Concurrent)

add_executable(telar-desktop main.cpp)

file(GLOB_RECURSE desktop_ui_scripts CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/ui/*.lua")

# A program that runs the Lua UI embeds its scripts.
function(desktop_embed_ui_scripts target)
  qt_add_resources(${target} ${target}_ui_scripts
    PREFIX "/telar/ui"
    BASE "${CMAKE_CURRENT_SOURCE_DIR}/ui"
    FILES ${desktop_ui_scripts}
  )
endfunction()

desktop_embed_ui_scripts(telar-desktop)

# The faces the GUI embeds, so terminal panes render with the same font by default. A program
# that draws terminals embeds them too.
set(desktop_font_directory "${CMAKE_CURRENT_SOURCE_DIR}/../../src/assets")
set(desktop_fonts
  "${desktop_font_directory}/JetBrainsMono-Regular.ttf"
  "${desktop_font_directory}/SymbolsNerdFontMono-Regular.ttf"
  "${desktop_font_directory}/IBMPlexSans-Regular.ttf"
  "${desktop_font_directory}/IBMPlexSans-SemiBold.ttf"
  "${desktop_font_directory}/provider-symbols-320x64.rgba"
)

function(desktop_embed_fonts target)
  qt_add_resources(${target} ${target}_fonts
    PREFIX "/telar/fonts"
    BASE "${desktop_font_directory}"
    FILES ${desktop_fonts}
  )
endfunction()

desktop_embed_fonts(telar-desktop)

if(APPLE)
  set(CMAKE_OBJCXX_COMPILER "${CMAKE_CXX_COMPILER}")
  enable_language(OBJCXX)
  set(CMAKE_OBJCXX_STANDARD 23)
  set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
  set(CMAKE_OBJCXX_EXTENSIONS OFF)
  find_library(APPKIT_FRAMEWORK AppKit REQUIRED)
  find_library(APPLICATION_SERVICES_FRAMEWORK ApplicationServices REQUIRED)
  find_library(CORE_TEXT_FRAMEWORK CoreText REQUIRED)
  file(GLOB_RECURSE desktop_native_sources CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/native-backends/macos/*.mm")
  add_library(desktop-native OBJECT ${desktop_native_sources})
  target_compile_options(desktop-native PRIVATE -fobjc-arc)

  # Recent LLVM class-selector stubs require a newer Apple linker.
  include(CheckCompilerFlag)
  check_compiler_flag(OBJCXX "-fno-objc-msgsend-class-selector-stubs" desktop_has_class_selector_stub_flag)
  if(desktop_has_class_selector_stub_flag)
    target_compile_options(desktop-native PRIVATE -fno-objc-msgsend-class-selector-stubs)
  endif()

  target_link_libraries(desktop-native PUBLIC "${APPKIT_FRAMEWORK}" "${APPLICATION_SERVICES_FRAMEWORK}" "${CORE_TEXT_FRAMEWORK}")
  target_link_libraries(desktop-native PUBLIC desktop-ui)
  # Optical text shares the GUI's font smoothing and reads the CoreText font behind Qt's.
  target_include_directories(desktop-native PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../../src/gui/native")
  target_link_libraries(desktop-native PRIVATE Qt6::GuiPrivate)
  target_link_libraries(telar-desktop PRIVATE desktop-native)
endif()

if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  enable_language(C)
  pkg_check_modules(WLROOTS REQUIRED IMPORTED_TARGET wlroots-0.20>=0.20.2)
  pkg_check_modules(WAYLAND REQUIRED IMPORTED_TARGET wayland-server wayland-client xkbcommon libinput pixman-1)
  file(GLOB desktop_linux_sources CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/native-backends/linux/*.cpp")
  file(GLOB desktop_linux_c_sources CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/native-backends/linux/*.c")
  add_library(desktop-native OBJECT ${desktop_linux_sources} ${desktop_linux_c_sources})
  find_program(WAYLAND_SCANNER wayland-scanner REQUIRED)
  pkg_check_modules(WLR_PROTOCOLS REQUIRED wlr-protocols)
  pkg_get_variable(WLR_PROTOCOLS_DIR wlr-protocols pkgdatadir)
  foreach(protocol wlr-layer-shell-unstable-v1 wlr-output-power-management-unstable-v1)
    set(protocol_header "${CMAKE_CURRENT_BINARY_DIR}/${protocol}-protocol.h")
    add_custom_command(OUTPUT "${protocol_header}"
      COMMAND "${WAYLAND_SCANNER}" server-header "${WLR_PROTOCOLS_DIR}/unstable/${protocol}.xml" "${protocol_header}"
      DEPENDS "${WLR_PROTOCOLS_DIR}/unstable/${protocol}.xml" VERBATIM)
    target_sources(desktop-native PRIVATE "${protocol_header}")
  endforeach()
  target_compile_definitions(desktop-native PRIVATE WLR_USE_UNSTABLE)
  target_include_directories(desktop-native PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
  target_link_libraries(desktop-native PUBLIC desktop-ui Qt6::GuiPrivate PkgConfig::WLROOTS PkgConfig::WAYLAND)
  target_link_libraries(telar-desktop PRIVATE desktop-native)
  install(TARGETS telar-desktop RUNTIME DESTINATION bin)
  install(FILES native-backends/linux/telar.desktop DESTINATION share/wayland-sessions)
  install(FILES native-backends/linux/telar-desktop.desktop DESTINATION share/applications)
  install(FILES licenses/wlroots.txt DESTINATION share/licenses/telar-desktop)
  install(FILES native-backends/linux/telar-portals.conf DESTINATION share/xdg-desktop-portal)
  # Wallpapers stay files the desktop finds by name, not resources inside the executable.
  install(DIRECTORY assets/wallpapers/ DESTINATION share/telar/wallpapers)
endif()

target_link_libraries(telar-desktop PRIVATE desktop-ui desktop-core)

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

# Programs name the libraries they need beyond the core; those that drive the native backend
# name its libraries and their own Objective-C++ sources.
set(layout_dbg_libraries desktop-ui)
set(traffic_dbg_libraries desktop-ui PkgConfig::LUAJIT)
# Terminals draw optical text through the native backend on macOS.
if(APPLE)
  set(terminal_ui_dbg_libraries desktop-native)
  set(surfaces_dbg_libraries desktop-native PkgConfig::LUAJIT)
else()
  set(terminal_ui_dbg_libraries desktop-ui)
  set(surfaces_dbg_libraries desktop-ui PkgConfig::LUAJIT)
endif()
set(spaces_dbg_native_sources debug/support/spaces_probe.mm)
set(spaces_dbg_native_libraries desktop-native)
set(input_router_dbg_native_libraries desktop-native)
set(external_window_dbg_native_sources debug/support/external_window_probe.mm)
set(external_window_dbg_native_libraries desktop-native "-framework QuartzCore")
set(layers_dbg_native_sources debug/support/external_window_probe.mm debug/support/layers_probe.mm)
set(layers_dbg_native_libraries desktop-native Qt6::Quick "-framework QuartzCore")
set(refused_size_dbg_native_libraries desktop-native)
set(keyboard_focus_dbg_native_sources debug/support/external_window_probe.mm debug/support/keyboard_focus_probe.mm)
set(keyboard_focus_dbg_native_libraries desktop-native "-framework QuartzCore")
set(window_observer_dbg_native_sources debug/support/external_window_probe.mm debug/support/window_observer_probe.mm)
set(window_observer_dbg_native_libraries desktop-native "-framework QuartzCore")

file(GLOB_RECURSE desktop_programs CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/debug/*.cpp")
list(FILTER desktop_programs EXCLUDE REGEX "/debug/support/")
foreach(source IN LISTS desktop_programs)
  file(RELATIVE_PATH program "${CMAKE_CURRENT_SOURCE_DIR}/debug" "${source}")
  string(REGEX REPLACE "\\.cpp$" "" program "${program}")
  string(REPLACE "/" "-" program "${program}")
  if(DEFINED ${program}_native_libraries AND NOT APPLE)
    continue()
  endif()
  add_executable("${program}" "${source}")
  target_link_libraries("${program}" PRIVATE desktop-debug-support ${${program}_native_libraries} ${${program}_libraries})
  if(DEFINED ${program}_native_sources)
    target_sources("${program}" PRIVATE ${${program}_native_sources})
    target_compile_options("${program}" PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
    if(desktop_has_class_selector_stub_flag)
      target_compile_options("${program}" PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fno-objc-msgsend-class-selector-stubs>")
    endif()
  endif()
  add_dependencies(desktop-editor "${program}")
endforeach()

desktop_embed_fonts(terminal_ui_dbg)
desktop_embed_fonts(surfaces_dbg)
desktop_embed_ui_scripts(surfaces_dbg)

option(TELAR_DESKTOP_CONTROL_TESTS "Build isolated control-query desktop tests" OFF)
if(TELAR_DESKTOP_CONTROL_TESTS)
  enable_testing()
  add_executable(clipboard-consent-tests tests/clipboard_consent_test.cpp)
  target_include_directories(clipboard-consent-tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
  target_link_libraries(clipboard-consent-tests PRIVATE Qt6::Quick)
  add_test(NAME clipboard-consent-tests COMMAND clipboard-consent-tests)
  set_tests_properties(clipboard-consent-tests PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software")
  add_executable(clipboard-connection-tests tests/clipboard_connection_test.cpp)
  if(APPLE)
    target_link_libraries(clipboard-connection-tests PRIVATE desktop-native Qt6::Network)
  else()
    target_link_libraries(clipboard-connection-tests PRIVATE desktop-ui Qt6::Network)
  endif()
  desktop_embed_fonts(clipboard-connection-tests)
  add_test(NAME clipboard-connection-tests COMMAND clipboard-connection-tests)
  add_test(NAME clipboard-deadline-tests COMMAND clipboard-connection-tests --deadline-only)
  set_tests_properties(clipboard-deadline-tests PROPERTIES TIMEOUT 40 ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software")
  set_tests_properties(clipboard-connection-tests PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software")
endif()
