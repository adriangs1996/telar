telar_add_qml_sources(gui-quick
  SOURCES
    history_controller.cpp
    history_pointer.cpp
  QML_FILES
    HistoryEmpty.qml
    HistoryFilterChip.qml
    HistoryFilters.qml
    HistoryFooter.qml
    HistoryInspector.qml
    HistoryKeys.qml
    HistoryMeta.qml
    HistoryPanel.qml
    HistoryRow.qml
    HistorySearchBar.qml)
add_subdirectory(layout)

