namespace telar::gui {

struct PaletteAction {
  BindingActionKind action;
  std::string_view label;
};

inline constexpr auto palette_actions = std::to_array<PaletteAction>({
  {.action = BindingActionKind::split_horizontal, .label = "Split right"},
  {.action = BindingActionKind::split_vertical, .label = "Split down"},
  {.action = BindingActionKind::focus_left, .label = "Focus pane left"},
  {.action = BindingActionKind::focus_right, .label = "Focus pane right"},
  {.action = BindingActionKind::focus_up, .label = "Focus pane up"},
  {.action = BindingActionKind::focus_down, .label = "Focus pane down"},
  {.action = BindingActionKind::toggle_pane_fullscreen, .label = "Toggle pane fullscreen"},
  {.action = BindingActionKind::close_pane, .label = "Close pane"},
  {.action = BindingActionKind::new_tab, .label = "New tab"},
  {.action = BindingActionKind::rename_tab, .label = "Rename tab"},
  {.action = BindingActionKind::close_tab, .label = "Close tab"},
  {.action = BindingActionKind::next_tab, .label = "Next tab"},
  {.action = BindingActionKind::previous_tab, .label = "Previous tab"},
  {.action = BindingActionKind::move_tab_previous, .label = "Move tab left"},
  {.action = BindingActionKind::move_tab_next, .label = "Move tab right"},
  {.action = BindingActionKind::new_workspace, .label = "New context"},
  {.action = BindingActionKind::rename_workspace, .label = "Rename context"},
  {.action = BindingActionKind::toggle_sidebar, .label = "Toggle sidebar"},
  {.action = BindingActionKind::toggle_workspace_list, .label = "Toggle context list"},
  {.action = BindingActionKind::leave_worktree, .label = "Leave worktree for its project"},
  {.action = BindingActionKind::forget_gone_worktrees, .label = "Forget gone worktrees"},
  {.action = BindingActionKind::copy_mode, .label = "Enter copy mode"},
  {.action = BindingActionKind::history_palette, .label = "Search command history"},
  {.action = BindingActionKind::suggest_command, .label = "Suggest a command…"},
  {.action = BindingActionKind::path_picker, .label = "Insert a path"},
  {.action = BindingActionKind::machine_picker, .label = "Switch machine"},
  {.action = BindingActionKind::next_machine, .label = "Next machine"},
  {.action = BindingActionKind::previous_machine, .label = "Previous machine"},
  {.action = BindingActionKind::add_machine, .label = "Add machine"},
});

}
