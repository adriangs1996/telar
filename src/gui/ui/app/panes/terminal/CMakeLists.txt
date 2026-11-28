telar_add_qml_sources(gui-quick
  SOURCES
    copy_controller.cpp
    terminal_controller.cpp
    terminal_item.cpp
    terminal_links.cpp
    terminal_pointer.cpp
    terminal_scroll.cpp
  QML_FILES
    CommandRail.qml
    CommandSeparators.qml
    JumpToEnd.qml
    PromptLine.qml)
add_subdirectory(prompt)
add_subdirectory(links)
add_subdirectory(history)

