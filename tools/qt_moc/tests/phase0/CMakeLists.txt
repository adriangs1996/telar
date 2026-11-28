cmake_minimum_required(VERSION 4.0)

set(CMAKE_EXPERIMENTAL_CXX_IMPORT_STD "d0edc3af-4c50-42ea-a356-e2862fe7a444")

project(telar_qt_phase0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_CXX_MODULE_STD 1)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

set(QT_PREFIX "" CACHE PATH "Managed Qt6 installation prefix")
set(TELAR_QT_PLUGIN "" CACHE FILEPATH "Path to telar-qt-plugin.so")
set(TELAR_MOC "" CACHE FILEPATH "Path to telar-moc")

find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml Quick Test PATHS "${QT_PREFIX}/lib/cmake/Qt6" NO_DEFAULT_PATH)

add_library(telar-qt STATIC)
target_sources(telar-qt PUBLIC FILE_SET CXX_MODULES BASE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}" FILES telar_qt.cppm)
target_link_libraries(telar-qt PUBLIC Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Test)
set_target_properties(telar-qt PROPERTIES POSITION_INDEPENDENT_CODE ON AUTOMOC OFF)

# Phase 0 module interface: compiled with telar-qt-plugin.so (ZERO AUTOMOC!).
add_library(phase0-iface STATIC)
target_sources(phase0-iface PUBLIC FILE_SET CXX_MODULES BASE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}" FILES native_rounded_rectangle.cppm)
target_link_libraries(phase0-iface PUBLIC telar-qt)
target_compile_options(phase0-iface PUBLIC "-fplugin=${TELAR_QT_PLUGIN}")
set_target_properties(phase0-iface PROPERTIES POSITION_INDEPENDENT_CODE ON AUTOMOC OFF)

# Run telar-moc AFTER phase0-iface compiles its .pcm (zero cycle with CXX_MODULES!).
set(gen_dir "${CMAKE_CURRENT_BINARY_DIR}/generated")
set(moc_cpp "${gen_dir}/native_rounded_rectangle_moc.cpp")
set(meta_json "${gen_dir}/native_rounded_rectangle.metatypes.json")
set(reg_cpp "${gen_dir}/phase0_qmlreg.cpp")
set(qmltypes_out "${gen_dir}/phase0.qmltypes")

add_custom_command(
  OUTPUT "${moc_cpp}" "${meta_json}" "${reg_cpp}"
  COMMAND "${TELAR_MOC}"
    -p "${CMAKE_CURRENT_BINARY_DIR}"
    "--moc-out=${moc_cpp}"
    "--json-out=${meta_json}"
    "--reg-out=${reg_cpp}"
    --qt-module=telar.qt
    --uri=Telar.Phase0
    --major=1
    --minor=0
    "${CMAKE_CURRENT_SOURCE_DIR}/native_rounded_rectangle.cppm"
  DEPENDS phase0-iface "${CMAKE_CURRENT_SOURCE_DIR}/native_rounded_rectangle.cppm" "${TELAR_MOC}"
  COMMENT "Running telar-moc on native_rounded_rectangle.cppm"
  VERBATIM)

# Also verify Qt 6.12's own qmltyperegistrar accepts telar-moc's metatypes.json!
add_custom_command(
  OUTPUT "${qmltypes_out}"
  COMMAND "${QT_PREFIX}/libexec/qmltyperegistrar"
    "--generate-qmltypes=${qmltypes_out}"
    --import-name=Telar.Phase0
    --major-version=1
    --minor-version=0
    "--foreign-types=${QT_PREFIX}/metatypes/qt6core_metatypes.json,${QT_PREFIX}/metatypes/qt6gui_metatypes.json,${QT_PREFIX}/metatypes/qt6qml_metatypes.json,${QT_PREFIX}/metatypes/qt6quick_metatypes.json"
    -o "${gen_dir}/qmltyperegistrar_unused.cpp"
    "${meta_json}"
  DEPENDS "${meta_json}"
  COMMENT "Verifying metatypes.json with Qt 6.12 qmltyperegistrar"
  VERBATIM)

add_custom_target(phase0-qmltypes ALL DEPENDS "${qmltypes_out}")

# Implementation + generated moc + generated QML registration + test executable (ZERO AUTOMOC!).
add_executable(phase0-test
  native_rounded_rectangle.cpp
  "${moc_cpp}"
  "${reg_cpp}"
  main.cpp)
target_link_libraries(phase0-test PRIVATE phase0-iface telar-qt)
set_target_properties(phase0-test PROPERTIES AUTOMOC OFF)
