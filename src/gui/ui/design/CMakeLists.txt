telar_add_qml_sources(gui-quick
  SOURCES
    history_hint_projection.hpp
  QML_FILES
    BarBattery.qml
    BarMetric.qml
    BarPill.qml
    BarRing.qml
    BarSparkline.qml
    HistoryHint.qml
    PaletteButton.qml
    PaletteKeycap.qml
    PromptActions.qml
    PromptField.qml
    SystemSummary.qml)

add_subdirectory(controls)
add_subdirectory(elements)
