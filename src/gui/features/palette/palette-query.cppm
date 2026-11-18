// What the palette's field asks and how a navigation row reads, and the window actions it lists.
export module telar.gui.features.palette:query;

import std;

import telar.gui.foundation.actions;
import telar.gui.foundation.text;
import telar.base.ds;

// Interface: palette/navigation_label.cppm
export {
  namespace telar::gui::features::palette {

    class NavigationLabel {
    public:
      static constexpr std::size_t capacity = 160;
      static constexpr std::string_view detail_separator = "  ";
      static constexpr std::string_view tab_prefix = "tab ";

      void append(std::string_view text);
      void appendDetail(std::string_view detail);
      [[nodiscard]] std::string_view view() const noexcept;

    private:
      BoundedText<capacity> text_;
    };

  }
}

// Interface: palette/query.cppm
export {
  namespace telar::gui::features::palette {

    enum class PaletteMode : std::uint8_t {
      actions = '>',
      navigate = '@',
      suggest = '?',
      machines = ':',
    };

    struct PaletteQuery {
      static constexpr std::size_t maximum_bytes = 512;

      PaletteMode mode = PaletteMode::navigate;
      std::string_view text;

      [[nodiscard]] static constexpr ds::Option<PaletteMode> prefix(char byte) noexcept {
        switch (byte) {
        case static_cast<char>(PaletteMode::actions):
          return PaletteMode::actions;
        case static_cast<char>(PaletteMode::navigate):
          return PaletteMode::navigate;
        case static_cast<char>(PaletteMode::suggest):
          return PaletteMode::suggest;
        case static_cast<char>(PaletteMode::machines):
          return PaletteMode::machines;
        default:
          return ds::none;
        }
      }

      [[nodiscard]] static constexpr PaletteQuery parse(std::string_view prompt) noexcept {
        if (!prompt.empty()) {
          if (const auto mode = prefix(prompt.front())) {
            prompt.remove_prefix(1);

            return {.mode = *mode, .text = prompt};
          }
        }

        return {.text = prompt};
      }
    };

  }
}

// Interface: config/palette_actions.cppm
export {
  namespace telar::gui::features::palette {

    struct PaletteAction {
      BindingActionKind action;
      std::string_view label;
    };

    inline constexpr auto palette_actions = ds::Array<PaletteAction, 29>{{
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
    }};

  }
}
