namespace telar::gui {

struct DefaultBinding {
  KeyChord suffix;
  BindingAction action;
};

inline constexpr auto default_bindings = std::to_array<DefaultBinding>({
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = '-'}, .action = BindingAction{.kind = BindingActionKind::scroll_pane_up}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = '='}, .action = BindingAction{.kind = BindingActionKind::scroll_pane_down}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = '%'}, .action = BindingAction{.kind = BindingActionKind::split_horizontal}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = '"'}, .action = BindingAction{.kind = BindingActionKind::split_vertical}},
  {.suffix = KeyChord{.key = KeyChord::Key::left}, .action = BindingAction{.kind = BindingActionKind::focus_left}},
  {.suffix = KeyChord{.key = KeyChord::Key::right}, .action = BindingAction{.kind = BindingActionKind::focus_right}},
  {.suffix = KeyChord{.key = KeyChord::Key::up}, .action = BindingAction{.kind = BindingActionKind::focus_up}},
  {.suffix = KeyChord{.key = KeyChord::Key::down}, .action = BindingAction{.kind = BindingActionKind::focus_down}},
  {.suffix = KeyChord{.key = KeyChord::Key::left, .modifiers = static_cast<unsigned>(KeyChord::Modifier::shift)}, .action = BindingAction{.kind = BindingActionKind::resize_left}},
  {.suffix = KeyChord{.key = KeyChord::Key::right, .modifiers = static_cast<unsigned>(KeyChord::Modifier::shift)}, .action = BindingAction{.kind = BindingActionKind::resize_right}},
  {.suffix = KeyChord{.key = KeyChord::Key::up, .modifiers = static_cast<unsigned>(KeyChord::Modifier::shift)}, .action = BindingAction{.kind = BindingActionKind::resize_up}},
  {.suffix = KeyChord{.key = KeyChord::Key::down, .modifiers = static_cast<unsigned>(KeyChord::Modifier::shift)}, .action = BindingAction{.kind = BindingActionKind::resize_down}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = 'z'}, .action = BindingAction{.kind = BindingActionKind::toggle_pane_fullscreen}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = 's'}, .action = BindingAction{.kind = BindingActionKind::toggle_sidebar}},
  {.suffix = KeyChord{.key = KeyChord::Key::left, .modifiers = static_cast<unsigned>(KeyChord::Modifier::alt)}, .action = BindingAction{.kind = BindingActionKind::resize_sidebar_left}},
  {.suffix = KeyChord{.key = KeyChord::Key::right, .modifiers = static_cast<unsigned>(KeyChord::Modifier::alt)}, .action = BindingAction{.kind = BindingActionKind::resize_sidebar_right}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = 'w'}, .action = BindingAction{.kind = BindingActionKind::toggle_workspace_list}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = 'u'}, .action = BindingAction{.kind = BindingActionKind::leave_worktree}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = 'N'}, .action = BindingAction{.kind = BindingActionKind::new_workspace}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = 'W'}, .action = BindingAction{.kind = BindingActionKind::rename_workspace}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = 'x'}, .action = BindingAction{.kind = BindingActionKind::close_pane}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = 'd'}, .action = BindingAction{.kind = BindingActionKind::detach}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = '['}, .action = BindingAction{.kind = BindingActionKind::copy_mode}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = 'g'}, .action = BindingAction{.kind = BindingActionKind::goto_picker}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = '/'}, .action = BindingAction{.kind = BindingActionKind::history_palette}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = 'f'}, .action = BindingAction{.kind = BindingActionKind::path_picker}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = '?'}, .action = BindingAction{.kind = BindingActionKind::suggest_command}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = 'c'}, .action = BindingAction{.kind = BindingActionKind::new_tab}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = 'n'}, .action = BindingAction{.kind = BindingActionKind::next_tab}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = 'p'}, .action = BindingAction{.kind = BindingActionKind::previous_tab}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = '1'}, .action = BindingAction{.kind = BindingActionKind::select_tab}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = '2'}, .action = BindingAction{.kind = BindingActionKind::select_tab, .parameter = 1}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = '3'}, .action = BindingAction{.kind = BindingActionKind::select_tab, .parameter = 2}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = '4'}, .action = BindingAction{.kind = BindingActionKind::select_tab, .parameter = 3}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = '5'}, .action = BindingAction{.kind = BindingActionKind::select_tab, .parameter = 4}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = '6'}, .action = BindingAction{.kind = BindingActionKind::select_tab, .parameter = 5}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = '7'}, .action = BindingAction{.kind = BindingActionKind::select_tab, .parameter = 6}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = '8'}, .action = BindingAction{.kind = BindingActionKind::select_tab, .parameter = 7}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = '9'}, .action = BindingAction{.kind = BindingActionKind::select_tab, .parameter = 8}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = 'T'}, .action = BindingAction{.kind = BindingActionKind::rename_tab}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = 'X'}, .action = BindingAction{.kind = BindingActionKind::close_tab}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = ','}, .action = BindingAction{.kind = BindingActionKind::move_tab_previous}},
  {.suffix = KeyChord{.key = KeyChord::Key::character, .character = '.'}, .action = BindingAction{.kind = BindingActionKind::move_tab_next}},
});

}
