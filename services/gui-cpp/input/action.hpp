#pragma once

#include <array>
#include <cstdint>
#include <optional>
#include <string_view>
#include <utility>

namespace telar::gui {

enum class BindingActionKind : std::uint8_t {
  none,
  scroll_pane_up,
  scroll_pane_down,
  split_horizontal,
  split_vertical,
  focus_left,
  focus_right,
  focus_up,
  focus_down,
  navigate_left,
  navigate_right,
  navigate_up,
  navigate_down,
  resize_left,
  resize_right,
  resize_up,
  resize_down,
  toggle_pane_fullscreen,
  toggle_sidebar,
  resize_sidebar_left,
  resize_sidebar_right,
  toggle_workspace_list,
  leave_worktree,
  forget_gone_worktrees,
  new_workspace,
  rename_workspace,
  close_pane,
  new_tab,
  next_tab,
  previous_tab,
  rename_tab,
  close_tab,
  move_tab_previous,
  move_tab_next,
  select_tab,
  select_workspace,
  select_tab_offset,
  detach,
  copy_mode,
  goto_picker,
  history_palette,
  path_picker,
  suggest_command,
  close_panel,
  refresh_panel,
  next_machine,
  previous_machine,
  machine_picker,
  add_machine,
  palette,
  callback,
  expression,
  extended,
  command_tab,
};

struct BindingAction {
  BindingActionKind kind = BindingActionKind::none;
  std::int32_t parameter = 0;
  int reference = 0;
  std::uint64_t generation = 0;

  bool operator==(const BindingAction &) const = default;
};

inline constexpr auto builtin_binding_actions = std::to_array<std::pair<std::string_view, BindingActionKind>>({
    {"scroll-pane-up", BindingActionKind::scroll_pane_up},
    {"scroll-pane-down", BindingActionKind::scroll_pane_down},
    {"split-horizontal", BindingActionKind::split_horizontal},
    {"split-vertical", BindingActionKind::split_vertical},
    {"focus-left", BindingActionKind::focus_left},
    {"focus-right", BindingActionKind::focus_right},
    {"focus-up", BindingActionKind::focus_up},
    {"focus-down", BindingActionKind::focus_down},
    {"navigate-left", BindingActionKind::navigate_left},
    {"navigate-right", BindingActionKind::navigate_right},
    {"navigate-up", BindingActionKind::navigate_up},
    {"navigate-down", BindingActionKind::navigate_down},
    {"resize-left", BindingActionKind::resize_left},
    {"resize-right", BindingActionKind::resize_right},
    {"resize-up", BindingActionKind::resize_up},
    {"resize-down", BindingActionKind::resize_down},
    {"toggle-pane-fullscreen", BindingActionKind::toggle_pane_fullscreen},
    {"toggle-sidebar", BindingActionKind::toggle_sidebar},
    {"resize-sidebar-left", BindingActionKind::resize_sidebar_left},
    {"resize-sidebar-right", BindingActionKind::resize_sidebar_right},
    {"toggle-workspace-list", BindingActionKind::toggle_workspace_list},
    {"leave-worktree", BindingActionKind::leave_worktree},
    {"forget-gone-worktrees", BindingActionKind::forget_gone_worktrees},
    {"new-workspace", BindingActionKind::new_workspace},
    {"rename-workspace", BindingActionKind::rename_workspace},
    {"close-pane", BindingActionKind::close_pane},
    {"new-tab", BindingActionKind::new_tab},
    {"next-tab", BindingActionKind::next_tab},
    {"previous-tab", BindingActionKind::previous_tab},
    {"rename-tab", BindingActionKind::rename_tab},
    {"close-tab", BindingActionKind::close_tab},
    {"move-tab-previous", BindingActionKind::move_tab_previous},
    {"move-tab-next", BindingActionKind::move_tab_next},
    {"detach", BindingActionKind::detach},
    {"copy-mode", BindingActionKind::copy_mode},
    {"goto-picker", BindingActionKind::goto_picker},
    {"history-palette", BindingActionKind::history_palette},
    {"path-picker", BindingActionKind::path_picker},
    {"suggest-command", BindingActionKind::suggest_command},
    {"close-panel", BindingActionKind::close_panel},
    {"refresh-panel", BindingActionKind::refresh_panel},
    {"next-machine", BindingActionKind::next_machine},
    {"previous-machine", BindingActionKind::previous_machine},
    {"machine-picker", BindingActionKind::machine_picker},
    {"add-machine", BindingActionKind::add_machine},
});

inline std::optional<BindingAction> builtinBindingAction(std::string_view name) noexcept {
  for (const auto &[known, kind] : builtin_binding_actions) {
    if (name == known) {
      return BindingAction{.kind = kind};
    }
  }

  for (const auto &[prefix, kind] : {std::pair{std::string_view{"select-tab-"}, BindingActionKind::select_tab}, std::pair{std::string_view{"select-workspace-"}, BindingActionKind::select_workspace}}) {
    if (!name.starts_with(prefix)) {
      continue;
    }

    auto digits = name;
    digits.remove_prefix(prefix.size());
    if (digits.empty() || digits.front() == '_' || digits.back() == '_') {
      return {};
    }

    std::int32_t index = 0;
    constexpr std::int32_t decimal_base = 10;
    constexpr std::int32_t maximum_index = 255;
    for (const char digit : digits) {
      if (digit == '_') {
        continue;
      }

      if (digit < '0' || digit > '9') {
        return {};
      }

      index = (index * decimal_base) + (digit - '0');
      if (index > maximum_index) {
        return {};
      }
    }

    return index == 0 ? std::nullopt : std::optional{BindingAction{.kind = kind, .parameter = index - 1}};
  }

  return {};
}

}
