# Qt 6.12 wrapper modules: parse Qt's textual headers once into shared BMIs so src/gui/ui/
# compiles as pure C++23 modules without duplicating Qt ASTs across every unit.
add_library(gui-qt STATIC)
add_library(telar::gui::qt ALIAS gui-qt)
target_sources(gui-qt PUBLIC FILE_SET CXX_MODULES BASE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}" FILES
  qt.cppm
  qt-meta.cppm)
target_compile_features(gui-qt PUBLIC cxx_std_23)
target_link_libraries(gui-qt PUBLIC telar::build_flags
  Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick Qt6::QuickControls2 Qt6::Network Qt6::Concurrent Qt6::Svg)
target_compile_options(gui-qt PUBLIC ${TELAR_PROCESS_OPTIONS})
set_target_properties(gui-qt PROPERTIES POSITION_INDEPENDENT_CODE ON AUTOMOC OFF AUTOUIC OFF AUTORCC OFF)

add_library(gui-qt-private STATIC)
add_library(telar::gui::qt::private_gui ALIAS gui-qt-private)
target_sources(gui-qt-private PUBLIC FILE_SET CXX_MODULES BASE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}/private_gui" FILES
  private_gui/private_gui.cppm)
target_compile_features(gui-qt-private PUBLIC cxx_std_23)
target_link_libraries(gui-qt-private PUBLIC telar::build_flags Qt6::GuiPrivate)
target_compile_options(gui-qt-private PUBLIC ${TELAR_PROCESS_OPTIONS})
set_target_properties(gui-qt-private PROPERTIES POSITION_INDEPENDENT_CODE ON AUTOMOC OFF AUTOUIC OFF AUTORCC OFF)

# Module wrapper over the Objective-C++/native platform boundary headers used by src/gui/ui/.
add_library(gui-qt-platform STATIC)
add_library(telar::gui::qt::platform ALIAS gui-qt-platform)
target_sources(gui-qt-platform PUBLIC FILE_SET CXX_MODULES BASE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}/platform" FILES
  platform/platform.cppm)
target_compile_features(gui-qt-platform PUBLIC cxx_std_23)
target_link_libraries(gui-qt-platform PUBLIC telar::build_flags telar::base telar::tbc gui-foundation-core gui-platform gui-qt)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_link_libraries(gui-qt-platform PUBLIC telar::clipboard)
endif()
target_compile_options(gui-qt-platform PUBLIC ${TELAR_PROCESS_OPTIONS})
set_target_properties(gui-qt-platform PROPERTIES POSITION_INDEPENDENT_CODE ON AUTOMOC OFF AUTOUIC OFF AUTORCC OFF)

if(BUILD_TESTING)
  find_package(Qt6 ${TELAR_QT_VERSION} EXACT REQUIRED COMPONENTS Test
    PATHS "${TELAR_GUI_QT_PREFIX}/lib/cmake/Qt6" NO_DEFAULT_PATH)
  add_library(gui-qt-testing STATIC testing/testing.cpp)
  add_library(telar::gui::qt::testing ALIAS gui-qt-testing)
  target_sources(gui-qt-testing PUBLIC FILE_SET CXX_MODULES BASE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}/testing" FILES
    testing/testing.cppm)
  target_compile_features(gui-qt-testing PUBLIC cxx_std_23)
  target_link_libraries(gui-qt-testing PUBLIC telar::build_flags Qt6::Test Qt6::Quick)
  target_compile_options(gui-qt-testing PUBLIC ${TELAR_PROCESS_OPTIONS})
  set_target_properties(gui-qt-testing PROPERTIES POSITION_INDEPENDENT_CODE ON AUTOMOC OFF AUTOUIC OFF AUTORCC OFF)
endif()
