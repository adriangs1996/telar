# A script that the QML of this folder and its parent import by path, not a type.
set_source_files_properties(ComponentFit.js TARGET_DIRECTORY gui-quick PROPERTIES QT_QML_SKIP_QMLDIR_ENTRY TRUE)
telar_add_qml_sources(gui-quick
  SOURCES
    components_controller.cpp
    components_controller.hpp
  QML_FILES
    ComponentBranch.qml
    ComponentFit.js
    ComponentNode.qml
    ComponentOverflow.qml
    ComponentPanel.qml
    ComponentPick.qml
    ComponentSlot.qml
    ComponentTree.qml
  REGISTERS)

add_subdirectory(machine_chrome)
