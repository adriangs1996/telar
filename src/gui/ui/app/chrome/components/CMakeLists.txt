telar_add_qml_sources(gui-quick
  SOURCES
    components_controller.cpp
  QML_FILES
    ComponentBranch.qml
    ComponentFit.js
    ComponentNode.qml
    ComponentOverflow.qml
    ComponentPanel.qml
    ComponentPick.qml
    ComponentSlot.qml
    ComponentTree.qml)
add_subdirectory(machine_chrome)

