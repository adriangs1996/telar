telar_add_qml_sources(gui-quick
  SOURCES
    palette_controller.cpp
  QML_FILES
    PalettePanel.qml
  FP_CONTRACT_OFF
    palette_controller.cpp)
add_subdirectory(suggestions)

