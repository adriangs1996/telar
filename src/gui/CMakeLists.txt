telar_process(gui OPTIONS ${TELAR_WARNINGS} -ffp-contract=off QML ui)

option(TELAR_GUI_NATIVE "Build the native window" ON)
# clangd, lint and per-file incremental rebuilds need one compile command per source.
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
  set(telar_gui_batch_default 0)
else()
  set(telar_gui_batch_default 12)
endif()
set(TELAR_GUI_BATCH_SIZE ${telar_gui_batch_default} CACHE STRING "Sources compiled together in gui-quick; 0 compiles each one alone")

get_filename_component(TELAR_ROOT "../.." ABSOLUTE)
find_package(Python3 REQUIRED COMPONENTS Interpreter)
find_package(Threads REQUIRED)

file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(READ "${TELAR_ROOT}/lib/config/bootstrap.lua" TELAR_CONFIG_BOOTSTRAP)
configure_file(application/bootstrap.inc.in "${CMAKE_CURRENT_BINARY_DIR}/generated/gui_config_bootstrap.inc" @ONLY)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${TELAR_ROOT}/lib/config/bootstrap.lua")

include(cmake/fonts.cmake)

# What every domain of the GUI compiles and links with.
target_link_libraries(gui-settings INTERFACE tbc::tbc telar::shell telar::render ebnf::ebnf)
target_include_directories(gui-settings INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/generated")
target_link_libraries(gui-settings INTERFACE telar::config telar::machines gui-harfbuzz deps::ghostty_vt)

# The module domains of docs/build/modules.json (process_layers), lowest first.
foreach(domain IN ITEMS foundation features
    platform
    application)
  add_subdirectory(${domain})
endforeach()

add_library(gui-posix STATIC platform/clipboard_image_file.c foundation/system/system-peer_identity.cpp foundation/system/system-window_lease.cpp foundation/system/system-profile_file.cpp foundation/system/system-stdio_socket.cpp foundation/system/system-managed_directory.cpp foundation/system/system-process_group.cpp
  foundation/system/system-runtime_endpoint.cpp foundation/system/system-login_shell.cpp)
target_sources(gui-posix PRIVATE platform/platform-clipboard_image_pipe.cpp)
target_link_libraries(gui-posix PUBLIC gui-foundation-core gui-foundation-system gui-platform Threads::Threads)
add_executable(telar-gui-command platform/surface_command_main.c)
target_compile_definitions(telar-gui-command PRIVATE "$<$<PLATFORM_ID:Linux>:_GNU_SOURCE>")
target_compile_options(telar-gui-command PRIVATE ${TELAR_WARNINGS})
target_link_libraries(telar-gui-command PRIVATE telar::build_flags)

add_library(gui-editor-config INTERFACE)
target_link_libraries(gui-editor-config INTERFACE gui-settings deps::ghostty_vt)
target_include_directories(gui-editor-config INTERFACE "${CMAKE_CURRENT_BINARY_DIR}/generated")

file(GENERATE
  OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/clangd/config/compile_flags.txt"
  CONTENT "-xc++\n-std=c++${CMAKE_CXX_STANDARD}\n-I$<JOIN:$<REMOVE_DUPLICATES:$<TARGET_PROPERTY:gui-editor-config,INTERFACE_INCLUDE_DIRECTORIES>>,\n-I>\n-D$<JOIN:$<TARGET_PROPERTY:gui-editor-config,INTERFACE_COMPILE_DEFINITIONS>,\n-D>\n")

add_custom_target(gui-editor)
add_library(gui-editor-context INTERFACE)
target_link_libraries(gui-editor-context INTERFACE gui-editor-config)
file(GENERATE
  OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/clangd/domain/compile_flags.txt"
  CONTENT "-xc++\n-std=c++${CMAKE_CXX_STANDARD}\n-I$<JOIN:$<REMOVE_DUPLICATES:$<TARGET_PROPERTY:gui-editor-context,INTERFACE_INCLUDE_DIRECTORIES>>,\n-I>\n-D$<JOIN:$<TARGET_PROPERTY:gui-editor-context,INTERFACE_COMPILE_DEFINITIONS>,\n-D>\n")

if(TELAR_GUI_NATIVE)
  # The fonts domain's faces and shaping, which only the native window uses.
  add_library(gui-fonts-native STATIC foundation/fonts/fonts-face.cpp foundation/fonts/fonts-ligature_coverage.cpp foundation/fonts/fonts-font_requests.cpp foundation/fonts/fonts-row_text_layout.cpp)
  target_link_libraries(gui-fonts-native PUBLIC gui-foundation-core gui-foundation-terminal gui-foundation-fonts gui-harfbuzz)
  target_link_libraries(gui-editor-context INTERFACE gui-fonts-native)
  target_compile_options(gui-fonts-native PRIVATE -ffp-contract=off)

  include(cmake/qt.cmake)
  find_package(Qt6 ${TELAR_QT_VERSION} EXACT REQUIRED COMPONENTS Gui Qml Quick QuickControls2 Network Concurrent ShaderTools Svg
    PATHS "${TELAR_GUI_QT_PREFIX}/lib/cmake/Qt6" NO_DEFAULT_PATH)
  find_package(Qt6GuiPrivate ${TELAR_QT_VERSION} EXACT REQUIRED CONFIG
    PATHS "${TELAR_GUI_QT_PREFIX}/lib/cmake/Qt6GuiPrivate" NO_DEFAULT_PATH)
  qt_standard_project_setup(REQUIRES 6.7)
  add_library(gui-surface-command STATIC ui/app/chrome/components/surface_command.cpp)
  target_link_libraries(gui-surface-command PUBLIC gui-posix gui-platform Qt6::Core)
  add_dependencies(gui-surface-command telar-gui-command)

  add_library(gui-machine-profiles STATIC ui/app/overlays/machine_prompt/machine_profiles_source.cpp ui/app/overlays/machine_prompt/machine_profiles_source.hpp)
  target_link_libraries(gui-machine-profiles PUBLIC gui-posix gui-platform gui-application Qt6::Concurrent)
  if(Qt6_VERSION VERSION_GREATER_EQUAL 6.8)
    qt_policy(SET QTP0004 NEW)
  endif()

  # The platform domain's native window, fonts and clipboard images, on Qt.
  add_library(gui-platform-native STATIC foundation/system/system-host_name.cpp)
  target_link_libraries(gui-platform-native PUBLIC gui-foundation-system gui-foundation-fonts gui-platform gui-posix Qt6::Gui PRIVATE Qt6::Quick)
  if(APPLE)
    if(NOT DEFINED CMAKE_OBJCXX_COMPILER AND "$ENV{OBJCXX}" STREQUAL "" AND CMAKE_CXX_COMPILER_ID MATCHES "Clang")
      set(CMAKE_OBJCXX_COMPILER "${CMAKE_CXX_COMPILER}")
    endif()

    enable_language(OBJCXX)
    if(NOT DEFINED CMAKE_OBJC_COMPILER AND "$ENV{OBJC}" STREQUAL "" AND CMAKE_CXX_COMPILER_ID MATCHES "Clang")
      set(CMAKE_OBJC_COMPILER "${CMAKE_CXX_COMPILER}")
    endif()

    enable_language(OBJC)
    set(CMAKE_OBJCXX_STANDARD 23)
    set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
    include(CheckOBJCXXCompilerFlag)
    check_objcxx_compiler_flag(-fno-objc-msgsend-class-selector-stubs TELAR_GUI_HAS_OBJC_CLASS_STUB_CONTROL)
    target_sources(gui-platform-native PRIVATE platform/macos/window.mm platform/macos/blur_symbols.m platform/macos/text_input.mm platform/macos/scroll_event.mm platform/macos/clipboard_image_source.mm)
    target_sources(gui-platform-native PRIVATE platform/macos/font.mm platform/macos/glyph_rasterizer.mm foundation/fonts/fonts-glyph_rasterizer.cpp)
    target_sources(gui-platform-native PRIVATE platform/macos/optical_text.mm)
    target_sources(gui-platform-native PRIVATE platform/macos/file_drag.mm)
    target_link_libraries(gui-platform-native PRIVATE Qt6::GuiPrivate)
    target_compile_options(gui-platform-native PRIVATE "$<$<COMPILE_LANGUAGE:OBJC,OBJCXX>:-fobjc-arc>")
    if(TELAR_GUI_HAS_OBJC_CLASS_STUB_CONTROL)
      target_compile_options(gui-platform-native PRIVATE "$<$<COMPILE_LANGUAGE:OBJC,OBJCXX>:-fno-objc-msgsend-class-selector-stubs>")
    endif()

    target_link_libraries(gui-platform-native PRIVATE "-framework AppKit" "-framework CoreText" "-framework CoreGraphics" "-framework ImageIO" "-framework UniformTypeIdentifiers")
    # The clipboard image source test checks this source under the sanitizers.
    if(BUILD_TESTING AND TELAR_SANITIZERS)
      set_property(SOURCE platform/macos/clipboard_image_source.mm APPEND PROPERTY COMPILE_OPTIONS -fsanitize=address,undefined -fno-omit-frame-pointer)
    endif()

  elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    find_package(Fontconfig REQUIRED)
    find_package(Qt6 ${TELAR_QT_VERSION} EXACT REQUIRED COMPONENTS WaylandClient
      PATHS "${TELAR_GUI_QT_PREFIX}/lib/cmake/Qt6" NO_DEFAULT_PATH)
    find_package(Qt6WaylandClientPrivate ${TELAR_QT_VERSION} EXACT REQUIRED CONFIG
      PATHS "${TELAR_GUI_QT_PREFIX}/lib/cmake/Qt6WaylandClientPrivate" NO_DEFAULT_PATH)
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(GUI_WAYLAND_CLIENT REQUIRED IMPORTED_TARGET wayland-client)
    pkg_check_modules(GUI_XCB REQUIRED IMPORTED_TARGET xcb)
    find_program(GUI_WAYLAND_SCANNER wayland-scanner REQUIRED)
    set(GUI_BACKGROUND_EFFECT_XML "${CMAKE_CURRENT_SOURCE_DIR}/platform/linux/protocols/ext-background-effect-v1.xml")
    set(GUI_BACKGROUND_EFFECT_DIR "${CMAKE_CURRENT_BINARY_DIR}/gui-wayland")
    set(GUI_BACKGROUND_EFFECT_HEADER "${GUI_BACKGROUND_EFFECT_DIR}/ext-background-effect-v1-client-protocol.h")
    set(GUI_BACKGROUND_EFFECT_SERVER_HEADER "${GUI_BACKGROUND_EFFECT_DIR}/ext-background-effect-v1-server-protocol.h")
    set(GUI_BACKGROUND_EFFECT_CODE "${GUI_BACKGROUND_EFFECT_DIR}/ext-background-effect-v1-protocol.c")
    add_custom_command(OUTPUT "${GUI_BACKGROUND_EFFECT_HEADER}" "${GUI_BACKGROUND_EFFECT_CODE}" "${GUI_BACKGROUND_EFFECT_SERVER_HEADER}"
      COMMAND "${CMAKE_COMMAND}" -E make_directory "${GUI_BACKGROUND_EFFECT_DIR}"
      COMMAND "${GUI_WAYLAND_SCANNER}" client-header "${GUI_BACKGROUND_EFFECT_XML}" "${GUI_BACKGROUND_EFFECT_HEADER}"
      COMMAND "${GUI_WAYLAND_SCANNER}" server-header "${GUI_BACKGROUND_EFFECT_XML}" "${GUI_BACKGROUND_EFFECT_SERVER_HEADER}"
      COMMAND "${GUI_WAYLAND_SCANNER}" private-code "${GUI_BACKGROUND_EFFECT_XML}" "${GUI_BACKGROUND_EFFECT_CODE}"
      DEPENDS "${GUI_BACKGROUND_EFFECT_XML}" VERBATIM)
    target_sources(gui-platform-native PRIVATE foundation/system/system-background_effect.cpp
      platform/linux/background_effect.c "${GUI_BACKGROUND_EFFECT_HEADER}" "${GUI_BACKGROUND_EFFECT_CODE}")
    target_include_directories(gui-platform-native PRIVATE "${GUI_BACKGROUND_EFFECT_DIR}")
    target_link_libraries(gui-platform-native PRIVATE Qt6::WaylandClientPrivate PkgConfig::GUI_WAYLAND_CLIENT PkgConfig::GUI_XCB)
    target_link_libraries(gui-platform-native PRIVATE Fontconfig::Fontconfig)
    target_sources(gui-platform-native PRIVATE platform/linux/font.c)
    target_sources(gui-platform-native PRIVATE platform/linux/window.cpp platform/linux/clipboard_image_source.cpp platform/linux/clipboard_image_monitor.cpp platform/linux/xcb_clipboard_image_monitor.cpp platform/linux/wayland_clipboard_image_monitor.cpp)
    target_sources(gui-platform-native PRIVATE ui/kit/scene/optical_text_fallback.cpp)
  else()
    message(FATAL_ERROR "The GUI supports macOS and Linux")
  endif()

  add_library(gui-keyboard STATIC ui/kit/input/terminal_input.cpp)
  # It imports no domain; the lowest, gui-foundation-core, gives it the GUI's settings.
  target_link_libraries(gui-keyboard PUBLIC gui-foundation-core Qt6::Gui)

  add_library(gui-clipboard-images STATIC ui/app/panes/attachments/attachment_preview.cpp ui/app/panes/attachments/attachment_preview.hpp ui/app/panes/attachments/clipboard_images.cpp ui/app/panes/attachments/clipboard_images.hpp)
  target_link_libraries(gui-clipboard-images PUBLIC gui-platform-native gui-application Qt6::Concurrent)

  qt_add_library(gui-quick STATIC)
  target_link_libraries(gui-quick PRIVATE Qt6::GuiPrivate)
  target_link_libraries(gui-quick PUBLIC gui-clipboard-images)
  set_source_files_properties(ui/app/panes/attachments/attachment_preview.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")

  target_link_libraries(gui-quick PUBLIC gui-foundation-core gui-foundation-system gui-foundation-text
    gui-foundation-terminal gui-foundation-fonts gui-foundation-actions gui-foundation-keys gui-foundation-model
    gui-foundation-agents gui-foundation-drawing gui-foundation-forms gui-foundation-icons
    gui-platform
    gui-application gui-platform-native gui-keyboard gui-fonts-native gui-machine-profiles Qt6::Quick
    Qt6::QuickControls2 Qt6::Network Qt6::Concurrent)
  # Most of a gui-quick compilation parses the same Qt headers again; the ones
  # that at least two in five Qt adapters include are parsed once per build.
  option(TELAR_GUI_PRECOMPILED_HEADERS "Precompile the Qt headers shared by gui-quick sources" ON)
  if(TELAR_GUI_PRECOMPILED_HEADERS)
    target_precompile_headers(gui-quick PRIVATE
      <QByteArray> <QColor> <QDir> <QFont> <QFutureWatcher> <QHash> <QIODevice> <QImage>
      <QKeyEvent> <QList> <QMetaObject> <QMouseEvent> <QObject> <QPointF> <QPointer>
      <QQuickItem> <QQuickWindow> <QRectF> <QSizeF> <QString> <QStringList> <QThread>
      <QTimer> <QVariant> <QVariantMap> <QWindow> <QtQml/qqmlregistration.h>)
  endif()
  set(TELAR_GUI_LINK_HOST_HEADER "" CACHE FILEPATH "Header selecting a compile-time external link host")
  if(TELAR_GUI_LINK_HOST_HEADER)
    get_filename_component(gui_link_host_header "${TELAR_GUI_LINK_HOST_HEADER}" ABSOLUTE)
    if(NOT EXISTS "${gui_link_host_header}")
      message(FATAL_ERROR "TELAR_GUI_LINK_HOST_HEADER does not exist: ${gui_link_host_header}")
    endif()

    # The header is included where the link host is chosen, not before every source: a module
    # unit must start with its module declaration.
    target_compile_definitions(gui-quick PUBLIC TELAR_GUI_CUSTOM_LINK_HOST=1 "TELAR_GUI_LINK_HOST_HEADER=\"${gui_link_host_header}\"")
  endif()

  target_link_libraries(gui-quick PRIVATE gui-surface-command Qt6::Svg)
  add_custom_target(gui-editor-ui
    COMMAND Python3::Interpreter "${CMAKE_CURRENT_SOURCE_DIR}/tools/create_editor_database.py" --build-dir "${CMAKE_BINARY_DIR}"
    DEPENDS tools/create_editor_database.py
    VERBATIM)
  add_dependencies(gui-editor gui-editor-ui)
  # Run by hand by tools/check_notification_desktop.py, so a tree configured without
  # tests builds it too.
  telar_add_test(gui-host-effects-smoke QT PROBE SOURCES tools/host_effects_smoke.cpp
    LIBRARIES gui-foundation-model gui-foundation-agents gui-foundation-core gui-foundation-text
      gui-features-history gui-platform gui-application deps::ghostty_vt
      Qt6::Core Qt6::Gui)

  qt_add_shaders(gui-quick gui-curve-shaders
    PREFIX "/telar/shaders"
    BASE "${CMAKE_CURRENT_SOURCE_DIR}/ui/kit/scene/shaders"
    BATCHABLE
    FILES ui/kit/scene/shaders/alpha_mask.vert ui/kit/scene/shaders/alpha_mask.frag ui/kit/scene/shaders/nearest_alpha_mask.frag ui/kit/scene/shaders/filtered_alpha_mask.frag ui/kit/scene/shaders/tab_caption.frag)

  qt_add_shaders(gui-quick gui-shape-shaders
    PREFIX "/telar/shaders"
    BASE "${CMAKE_CURRENT_SOURCE_DIR}/ui/kit/scene/shaders"
    BATCHABLE
    PERTARGETCOMPILE
    FILES ui/kit/scene/shaders/rounded_rectangle.vert ui/kit/scene/shaders/rounded_rectangle.frag)

  qt_add_shaders(gui-quick gui-straight-mask-shaders
    PREFIX "/telar/shaders"
    BASE "${CMAKE_CURRENT_SOURCE_DIR}/ui/kit/scene/shaders"
    BATCHABLE
    DEFINES TELAR_STRAIGHT_ALPHA=1
    OUTPUTS straight/alpha_mask.frag.qsb straight/nearest_alpha_mask.frag.qsb straight/filtered_alpha_mask.frag.qsb
    FILES ui/kit/scene/shaders/alpha_mask.frag ui/kit/scene/shaders/nearest_alpha_mask.frag ui/kit/scene/shaders/filtered_alpha_mask.frag)

  # Each folder of ui/ adds its sources and hands its QML files up (telar_add_qml_sources).
  add_subdirectory(ui)
  get_target_property(gui_quick_qml_files gui-quick TELAR_QML_FILES)
  qt_add_qml_module(gui-quick
    URI Telar.Gui
    VERSION 1.0
    OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/Telar/Gui"
    QML_FILES ${gui_quick_qml_files})

  qt_add_executable(telar-gui main.cpp)
  if(APPLE)
    target_link_options(telar-gui PRIVATE -Wl,-headerpad_max_install_names)
    add_executable(telar-gui-launcher tools/macos_launcher.cpp foundation/system/system-login_shell.cpp)
    target_link_libraries(telar-gui-launcher PRIVATE gui-foundation-system)
    target_compile_options(telar-gui-launcher PRIVATE -Wall -Wextra -Werror)
    target_link_options(telar-gui-launcher PRIVATE -Wl,-headerpad_max_install_names)
    set_target_properties(telar-gui-launcher PROPERTIES AUTOMOC OFF AUTOUIC OFF AUTORCC OFF)
    add_dependencies(telar-gui telar-gui-launcher)
  endif()
  target_link_libraries(telar-gui PRIVATE gui-platform gui-quick gui-quickplugin)
  add_dependencies(telar-gui telar-gui-command)
  # Run by hand by tools/measure_startup.py, in Release too, so a tree configured
  # without tests builds it.
  telar_add_test(gui-startup-probe QT PROBE SOURCES tools/startup_probe.cpp LIBRARIES gui-quick gui-quickplugin)
  # Shows a QML file of the ignored playground/ and shows it again when it changes.
  telar_add_test(gui-playground QT PROBE SOURCES tools/playground.cpp LIBRARIES gui-quick gui-quickplugin)

  set(gui_font_directory "${TELAR_ROOT}/assets")
  qt_add_resources(gui-quick gui-fonts
    PREFIX "/telar/fonts"
    BASE "${gui_font_directory}"
    FILES "${gui_font_directory}/JetBrainsMono-Regular.ttf" "${gui_font_directory}/SymbolsNerdFontMono-Regular.ttf" "${gui_font_directory}/IBMPlexSans-Regular.ttf" "${gui_font_directory}/IBMPlexSans-SemiBold.ttf" "${gui_font_directory}/TelarForma-Regular.ttf" "${gui_font_directory}/provider-symbols-320x64.rgba" "${gui_font_directory}/telar-mark-mono.svg" "${gui_font_directory}/telar-mark.svg" "${gui_font_directory}/telar-mark-shade.svg" "${gui_font_directory}/telar-mark-vesper.svg" "${gui_font_directory}/telar-mark-catppuccin.svg" "${gui_font_directory}/telar-mark-tokyo-night.svg" "${gui_font_directory}/telar-mark-pierre-dark.svg" "${gui_font_directory}/telar-mark-pierre-dark-soft.svg" "${gui_font_directory}/telar-mark-kanagawa.svg" "${gui_font_directory}/telar-mark-kanagawa-dragon.svg" "${gui_font_directory}/telar-mark-terminal.svg" "${gui_font_directory}/telar-mark-cybervenom.svg" "${gui_font_directory}/telar-mark-zenburn.svg")

  # Lucide line icons (ISC), which the mark item tints.
  set(gui_icon_directory "${TELAR_ROOT}/assets/icons")
  qt_add_resources(gui-quick gui-icons
    PREFIX "/telar/icons"
    BASE "${gui_icon_directory}"
    FILES "${gui_icon_directory}/bot.svg" "${gui_icon_directory}/chevron-down.svg" "${gui_icon_directory}/chevron-right.svg" "${gui_icon_directory}/git-branch.svg" "${gui_icon_directory}/server.svg" "${gui_icon_directory}/square-terminal.svg")

  add_dependencies(gui-editor gui-quick)

  telar_verify_qt_packages()
  install(TARGETS telar-gui BUNDLE DESTINATION . RUNTIME DESTINATION bin)
  install(TARGETS telar-gui-command RUNTIME DESTINATION bin)
  install(FILES licenses/cell-glyphs.txt DESTINATION share/licenses/telar-gui)
  install(FILES licenses/ghostty-vt.txt DESTINATION share/licenses/telar-gui)
  install(FILES "${TELAR_ROOT}/assets/icons/LICENSE" DESTINATION share/licenses/telar-gui RENAME lucide.txt)
  install(FILES "${gui_font_directory}/JetBrainsMono-OFL.txt" "${gui_font_directory}/TelarForma-OFL.txt" DESTINATION share/licenses/telar-gui)
endif()

# Nearly all of a gui-quick compilation is its imported BMIs and Qt headers, which
# every source repeats, so sources compiled together cost little more than one.
# CMake's UNITY_BUILD refuses sources it scans for modules; ordinary generated
# units including them keep the native dependency scan. File-local names must
# therefore stay unique across the batched ui/*.cpp sources.
function(telar_gui_batch_sources target batch_size)
  get_target_property(target_sources ${target} SOURCES)
  set(kept)
  set(batched)
  # The folders of ui/ add their sources by absolute path (CMP0076).
  set(ui "${CMAKE_CURRENT_SOURCE_DIR}/ui")
  foreach(source IN LISTS target_sources)
    cmake_path(ABSOLUTE_PATH source BASE_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}" NORMALIZE OUTPUT_VARIABLE path)
    cmake_path(IS_PREFIX ui "${path}" NORMALIZE in_ui)
    if(in_ui AND path MATCHES "\\.cpp$")
      # The GUI's domains already give every gui-quick source -ffp-contract=off
      # (telar_process OPTIONS), so a source that only repeats it can share a unit.
      get_source_file_property(source_options "${path}" COMPILE_OPTIONS)
      if(NOT source_options OR source_options STREQUAL "-ffp-contract=off")
        list(APPEND batched "${path}")
        # AUTOMOC finds a header through its source, which leaves the target.
        string(REGEX REPLACE "\\.cpp$" ".hpp" header "${path}")
        if(EXISTS "${header}")
          list(APPEND kept "${header}")
        endif()
        continue()
      endif()
    endif()
    list(APPEND kept "${source}")
  endforeach()
  list(SORT batched)
  list(LENGTH batched batched_count)
  set(index 0)
  set(batch 0)
  while(index LESS batched_count)
    list(SUBLIST batched ${index} ${batch_size} members)
    set(content "")
    foreach(member IN LISTS members)
      string(APPEND content "#include \"${member}\"\n")
    endforeach()
    set(unit "${CMAKE_CURRENT_BINARY_DIR}/${target}_batch_${batch}.cpp")
    file(GENERATE OUTPUT "${unit}" CONTENT "${content}")
    set_source_files_properties("${unit}" PROPERTIES GENERATED TRUE CXX_SCAN_FOR_MODULES ON SKIP_AUTOMOC ON)
    list(APPEND kept "${unit}")
    math(EXPR index "${index} + ${batch_size}")
    math(EXPR batch "${batch} + 1")
  endwhile()
  list(REMOVE_DUPLICATES kept)
  set_target_properties(${target} PROPERTIES SOURCES "${kept}")
endfunction()
if(TARGET gui-quick AND TELAR_GUI_BATCH_SIZE GREATER 0)
  telar_gui_batch_sources(gui-quick ${TELAR_GUI_BATCH_SIZE})
endif()

# moc includes the textual QObject headers, which import domain modules. Their
# generated translation units must participate in the same native dependency scan.
# telar_gui_scan_moc_imports() does so for the targets of the calling directory.
function(telar_gui_scan_moc_imports)
  get_property(gui_targets DIRECTORY PROPERTY BUILDSYSTEM_TARGETS)
  foreach(gui_target IN LISTS gui_targets)
    get_target_property(gui_automoc ${gui_target} AUTOMOC)
    if(gui_automoc)
      get_target_property(gui_autogen_directory ${gui_target} AUTOGEN_BUILD_DIR)
      if(NOT gui_autogen_directory)
        set(gui_autogen_directory "${CMAKE_CURRENT_BINARY_DIR}/${gui_target}_autogen")
      endif()
      # CMake deliberately disables scanning on its synthetic moc source. A
      # separate ordinary generated unit lets the scanner discover header imports.
      set_source_files_properties("${gui_autogen_directory}/mocs_compilation.cpp"
        PROPERTIES HEADER_FILE_ONLY ON)
      set(gui_moc_imports "${CMAKE_CURRENT_BINARY_DIR}/${gui_target}_moc_imports.cpp")
      file(GENERATE OUTPUT "${gui_moc_imports}"
        CONTENT "#include \"${gui_autogen_directory}/mocs_compilation.cpp\"\n")
      set_source_files_properties("${gui_moc_imports}" PROPERTIES GENERATED TRUE CXX_SCAN_FOR_MODULES ON SKIP_AUTOMOC ON)
      target_sources(${gui_target} PRIVATE "${gui_moc_imports}")
    endif()
  endforeach()
endfunction()

if(BUILD_TESTING)
  add_subdirectory(tests)
endif()
telar_gui_scan_moc_imports()

# The quality checks cover the GUI's libraries and programs; the tests register themselves.
telar_register_checks(gui-posix CHECKS ${TELAR_CHECKS})
if(TELAR_GUI_NATIVE)
  telar_register_checks(gui-fonts-native gui-surface-command gui-machine-profiles gui-platform-native gui-keyboard
    gui-clipboard-images gui-quick telar-gui CHECKS ${TELAR_CHECKS})
  if(APPLE)
    telar_register_checks(telar-gui-launcher CHECKS ${TELAR_CHECKS})
  endif()
endif()

# Probes and smoke tools run by hand or by tools/ scripts, never by CTest: building them on
# every test run costs a full module compile each. `cmake --build out --target gui-probes`
# builds the ones this platform and configuration define.
telar_add_probes(gui-probes)
