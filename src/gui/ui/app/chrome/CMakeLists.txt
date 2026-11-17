telar_add_qml_sources(gui-quick
  SOURCES
    sidebar_controller.cpp
    sidebar_controller.hpp
  QML_FILES
    MetricsGroup.qml
    NavigationBar.qml
    Sidebar.qml
    StatusBar.qml
  FP_CONTRACT_OFF
    sidebar_controller.cpp
  REGISTERS)

add_subdirectory(activity)
add_subdirectory(workspaces)
add_subdirectory(components)
add_subdirectory(tabs)
add_subdirectory(mode_bar)
