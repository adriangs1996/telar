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

    // `all` searches every kind of row at once; a leading prefix narrows the search to one kind.
    enum class PaletteMode : std::uint8_t {
      all = 0,
      actions = '>',
      navigate = '@',
      suggest = '?',
      machines = ':',
    };

    struct PaletteQuery {
      static constexpr std::size_t maximum_bytes = 512;

      PaletteMode mode = PaletteMode::all;
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

    // How well a label matches a query typed in the palette: every query byte must appear in the
    // label in order, ignoring ASCII case. Matches that start words and run together score higher,
    // and gaps cost, so "code" prefers "Claude Code" to "Enter copy mode".
    struct PaletteScore {
      static constexpr std::int32_t match = 16;
      static constexpr std::int32_t boundary_bonus = 10;
      static constexpr std::int32_t camel_bonus = 7;
      static constexpr std::int32_t consecutive_bonus = 4;
      static constexpr std::int32_t first_multiplier = 2;
      static constexpr std::int32_t gap_start = 3;
      static constexpr std::int32_t gap_extension = 1;
      static constexpr std::uint32_t base = 4096;

      // Nothing when the label does not contain the query; 1 for an empty query, which keeps
      // every row in its source order.
      [[nodiscard]] static ds::Option<std::uint32_t> of(std::string_view label, std::string_view query) noexcept;
    };

  }
}

// Interface: config/palette_actions.cppm
export {
  namespace telar::gui::features::palette {

    struct PaletteAction {
      BindingActionKind action;
      std::string_view label;
      // Closes or forgets something; a short query never preselects it.
      bool destructive = false;
    };

    inline constexpr auto palette_actions = ds::Array<PaletteAction, 41>{
        PaletteAction{.action = BindingActionKind::split_horizontal, .label = "Split right"},
        PaletteAction{.action = BindingActionKind::split_vertical, .label = "Split down"},
        PaletteAction{.action = BindingActionKind::focus_left, .label = "Focus pane left"},
        PaletteAction{.action = BindingActionKind::focus_right, .label = "Focus pane right"},
        PaletteAction{.action = BindingActionKind::focus_up, .label = "Focus pane up"},
        PaletteAction{.action = BindingActionKind::focus_down, .label = "Focus pane down"},
        PaletteAction{.action = BindingActionKind::toggle_pane_fullscreen, .label = "Toggle pane fullscreen"},
        PaletteAction{.action = BindingActionKind::close_pane, .label = "Close pane", .destructive = true},
        PaletteAction{.action = BindingActionKind::new_tab, .label = "New tab"},
        PaletteAction{.action = BindingActionKind::rename_tab, .label = "Rename tab"},
        PaletteAction{.action = BindingActionKind::close_tab, .label = "Close tab", .destructive = true},
        PaletteAction{.action = BindingActionKind::next_tab, .label = "Next tab"},
        PaletteAction{.action = BindingActionKind::previous_tab, .label = "Previous tab"},
        PaletteAction{.action = BindingActionKind::move_tab_previous, .label = "Move tab left"},
        PaletteAction{.action = BindingActionKind::move_tab_next, .label = "Move tab right"},
        PaletteAction{.action = BindingActionKind::new_workspace, .label = "New context"},
        PaletteAction{.action = BindingActionKind::rename_workspace, .label = "Rename context"},
        PaletteAction{.action = BindingActionKind::toggle_sidebar, .label = "Toggle sidebar"},
        PaletteAction{.action = BindingActionKind::toggle_workspace_list, .label = "Toggle context list"},
        PaletteAction{.action = BindingActionKind::leave_worktree, .label = "Leave worktree for its project"},
        PaletteAction{.action = BindingActionKind::forget_gone_worktrees, .label = "Forget gone worktrees", .destructive = true},
        PaletteAction{.action = BindingActionKind::copy_mode, .label = "Enter copy mode"},
        PaletteAction{.action = BindingActionKind::history_palette, .label = "Search command history"},
        PaletteAction{.action = BindingActionKind::suggest_command, .label = "Suggest a command…"},
        PaletteAction{.action = BindingActionKind::path_picker, .label = "Insert a path"},
        PaletteAction{.action = BindingActionKind::machine_picker, .label = "Switch machine"},
        PaletteAction{.action = BindingActionKind::next_machine, .label = "Next machine"},
        PaletteAction{.action = BindingActionKind::previous_machine, .label = "Previous machine"},
        PaletteAction{.action = BindingActionKind::add_machine, .label = "Add machine"},
        PaletteAction{.action = BindingActionKind::monitor, .label = "Open monitor"},
        PaletteAction{.action = BindingActionKind::process_picker, .label = "Find process"},
        PaletteAction{.action = BindingActionKind::process_terminate, .label = "Terminate process", .destructive = true},
        PaletteAction{.action = BindingActionKind::process_kill, .label = "Kill process", .destructive = true},
        PaletteAction{.action = BindingActionKind::process_stop, .label = "Pause process"},
        PaletteAction{.action = BindingActionKind::process_continue, .label = "Resume process"},
        PaletteAction{.action = BindingActionKind::process_lower_priority, .label = "Lower process priority"},
        PaletteAction{.action = BindingActionKind::process_copy_command, .label = "Copy process command"},
        PaletteAction{.action = BindingActionKind::process_focus_pane, .label = "Go to process pane"},
        PaletteAction{.action = BindingActionKind::process_review_stack, .label = "Review process stack"},
        PaletteAction{.action = BindingActionKind::process_review_files, .label = "Review process open files"},
        PaletteAction{.action = BindingActionKind::process_review_logs, .label = "Review process logs"},
    };

  }
}
