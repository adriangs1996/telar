telar_add_qml_sources(gui-quick
  SOURCES
    palette_controller.cpp
    palette_controller.hpp
  QML_FILES
    PalettePanel.qml
    PaletteRow.qml
  FP_CONTRACT_OFF
    palette_controller.cpp
  REGISTERS)

add_subdirectory(suggestions)
