telar_add_qml_sources(gui-quick
  SOURCES
    native_pane_attention.cpp
    pane_motion_layout.cpp
    panes_controller.cpp
  QML_FILES
    PaneActions.qml
    PaneArea.qml
  FP_CONTRACT_OFF
    native_pane_attention.cpp
    pane_motion_layout.cpp)
add_subdirectory(header)
add_subdirectory(terminal)
add_subdirectory(nvim)
add_subdirectory(documents)
add_subdirectory(attachments)

