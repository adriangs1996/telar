// The explorer's keys, with Neovim's grammar: a count, then a sequence of one or more keys that
// names a command, some of which take one more key as their argument.
export module telar.gui.features.explorer:keys;

import std;

import telar.base.memory.containers;
import telar.config.client;

export namespace telar::gui::features::explorer {

  using runtime::config::KeyChord;

  enum class Command : std::uint8_t {
    none,
    // Moving the selection.
    down,
    up,
    top,
    bottom,
    half_page_down,
    half_page_up,
    collapse,
    expand,
    toggle_fold,
    fold_all,
    unfold_all,
    next_change,
    previous_change,
    // Roots and jumps.
    enter,
    parent,
    workspace_root,
    home,
    scope_pane,
    scope_workspace,
    scope_machine,
    // The window goes to the next machine whose runtime answers for files.
    next_machine,
    mark,
    jump_to_mark,
    jump_back,
    jump_forward,
    next_lens,
    previous_lens,
    // Editing the listing as text.
    rename,
    rename_whole,
    create,
    // A new entry that is a directory, whatever its name ends in: no key names it, a row's menu does.
    create_directory,
    cut,
    yank,
    yank_relative,
    yank_name,
    paste,
    undo,
    write,
    // Windows.
    split_vertical,
    split_horizontal,
    next_window,
    previous_window,
    window_left,
    window_right,
    window_up,
    window_down,
    close_window,
    only_window,
    // Another window on the directory of the selected row: what `:vs` does with its path.
    split_here,
    pin,
    // Toward the panes.
    open,
    change_directory,
    split_shell,
    mention,
    repeat,
    // Git, sizes and what is listed.
    toggle_diff,
    stage,
    unstage,
    discard,
    commit,
    cycle_sort,
    toggle_hidden,
    toggle_ignored,
    refresh,
    // Modes.
    toggle_follow,
    visual,
    search,
    next_match,
    previous_match,
    command_line,
    help,
    quit,
    escape,
  };

  // The text of a key in Neovim's notation: `j`, `G`, `<C-w>`, `<CR>`.
  inline constexpr std::size_t notation_bytes = 16;
  using Notation = runtime::FixedText<notation_bytes>;

  // What Neovim calls the key; empty for one the explorer has no name for. An arrow reads as the
  // letter that moves the same way, and a page key as the half page.
  [[nodiscard]] Notation notation(KeyChord chord);

  // The keys typed toward a command: the count, and the sequence so far.
  inline constexpr std::size_t pending_bytes = 24;

  struct Keys {
    runtime::FixedText<pending_bytes> pending;
    std::uint32_t count = 0;
    bool counted = false;
  };

  // A command the keys named: with the count typed before it, 1 when none was, and for the
  // commands that take one, the key that follows them.
  struct Stroke {
    Command command = Command::none;
    std::uint32_t count = 1;
    bool counted = false;
    Notation argument;
  };

  // Takes one more key. A command when the keys so far name one, in `visual` among the ones a
  // selection takes; none while they start a longer sequence or name nothing, which forgets them.
  [[nodiscard]] Stroke feed(Keys& keys, KeyChord chord, bool visual);

  // Forgets the keys typed so far.
  void clear(Keys& keys) noexcept;

  // The keys that name `command` by default, for the hints and the help; empty for none.
  [[nodiscard]] std::string_view keysOf(Command command) noexcept;

}
