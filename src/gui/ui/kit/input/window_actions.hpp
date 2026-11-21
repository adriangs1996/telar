#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <QObject>
#include <QtQml/qqmlregistration.h>

#pragma once

namespace telar::gui::qt::window_actions {

  // What keys, pointers and widgets ask the window to do. The window runs them; a widget names
  // one in the signal it raises, so every widget may use this header.
  Q_NAMESPACE
  QML_NAMED_ELEMENT(WindowActions)
  // QML names every enum value with its enum: WindowActions.Action.palette.
  Q_CLASSINFO("RegisterEnumClassesUnscoped", "false")

  enum class Action : quint8 {
    none,
    new_tab,
    new_editor,
    new_editor_tab,
    select_tab,
    select_tab_index,
    next_tab,
    previous_tab,
    move_tab_next,
    move_tab_previous,
    focus_left,
    focus_right,
    focus_up,
    focus_down,
    resize_left,
    resize_right,
    resize_up,
    resize_down,
    detach,
    close_tab,
    select_workspace,
    focus_pane,
    select_agent,
    split_horizontal,
    split_vertical,
    close_pane,
    fullscreen,
    toggle_sidebar,
    toggle_workspace_list,
    history,
    palette,
    goto_picker,
    leave_worktree,
    forget_gone_worktrees,
    new_workspace,
    rename_tab,
    rename_workspace,
    cancel,
    copy_mode,
    path_picker,
    suggest_command,
    machine_picker,
    next_machine,
    previous_machine,
    add_machine,
    monitor,
    process_picker,
    process_terminate,
    process_kill,
    process_stop,
    process_continue,
    process_lower_priority,
    process_copy_command,
    process_focus_pane,
    process_review_stack,
    process_review_files,
    process_review_logs,
  };
  Q_ENUM_NS(Action)

  // What the palette's machine list asks of the chosen machine.
  enum class MachineEditAction : quint8 {
    rename,
    remove,
  };
  Q_ENUM_NS(MachineEditAction)

}
