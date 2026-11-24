// The explorer: the files of a machine listed as a tree a person moves in with Neovim's keys,
// edits as text and hands to the panes. The listing is a buffer: a rename, a removal, a new entry
// or a paste is a change typed but not written, and `:w` shows the plan the runtime applies.
export module telar.gui.features.explorer;

export import :cache;
export import :files;
export import :keys;
export import :presentation;
export import :transfers;
export import :view;

import std;

import telar.base.ds;
import telar.tbc;
import telar.wire.files;

export namespace telar::gui::features::explorer {

  // Opens the explorer with one window, on the machine `machine` and at the focused pane.
  void open(View& view, const State& state, const Context& context, std::uint64_t machine);

  void close(View& view) noexcept;

  // What an editor asks for the file it shows: the explorer, opened if it was not, with its
  // current window on the host, fixed at the directory that holds `path` and with `path`
  // selected. Without a path it goes to `directory`. False while something else waits for an
  // answer there: a plan, a field, a menu.
  bool reveal(View& view, const State& state, const Context& context, const Revealed& revealed);

  // Says on the line under the windows what could not be done past the explorer: by a session,
  // or by the window.
  void refuse(View& view, std::string_view text);

  // A window of `machine` that follows the focused pane goes where the pane is, when the pane
  // or its directory is another than the one it last followed. True when a window moved.
  bool follow(View& view, const Context& context, std::uint64_t machine);

  // Builds again the rows of the windows of `machine` from what its cache holds, and keeps each
  // selection on its path.
  void rebuild(View& view, const State& state, const Context& context, std::uint64_t machine);

  // Takes in what the cache of `machine` holds since the rows were built: they are built again
  // when what they list changed, and left as they are when a preview arrived that no window
  // unfolds as a diff, which what shows beside them reads again.
  void absorb(View& view, const State& state, const Context& context, std::uint64_t machine);

  // What the windows of `machine` show that its cache lacks; none when it holds it all or has
  // asked for it.
  [[nodiscard]] tbc::val_a<ds::Option<Need>> need(tbc::ref_a<View> view, const State& state, std::uint64_t machine);

  // A key in normal or visual mode, or over the plan and the help.
  [[nodiscard]] Action press(View& view, State& state, const Context& context, KeyChord chord);

  // What was typed in the mode's field, as it changes and when Enter ends it: the name of a row
  // in insert mode, the filter of a search, or a command.
  void typed(View& view, const State& state, const Context& context, std::string_view text);
  [[nodiscard]] Action submit(View& view, State& state, const Context& context, std::string_view text);

  // `<Tab>` on the command line `line`: completes the directory a command that goes somewhere
  // names, as far as one name or the start that several share reaches, and lists those. What it
  // completed is `view.completion`, and `view.completed` counts it; a directory not yet listed
  // is asked for, and the line is completed when it arrives.
  void complete(View& view, const State& state, const Context& context, std::string_view line);

  // Escape: leaves the mode, the selection or the filter.
  void cancel(View& view, const State& state, const Context& context);

  // The pointer chose a row of a window: alone, up to it from the selection, or beside the ones
  // picked.
  void select(View& view, const State& state, const Context& context, const Pick& pick);

  // The pointer asked for what Enter does on a row; and to fold or unfold a directory.
  [[nodiscard]] Action activate(View& view, State& state, const Context& context, const Pick& pick);
  void toggle(View& view, const State& state, const Context& context, const Pick& pick);

  // The pointer asked for the menu of a row of a window, or of the window itself with a row
  // past its last. A row outside the selection is selected first. The keys then move in the
  // menu, and Escape closes it.
  void openMenu(View& view, const State& state, const Context& context, const Pick& pick);

  // The pointer chose a line of the menu, which runs what its key runs.
  [[nodiscard]] Action chooseMenu(View& view, State& state, const Context& context, std::size_t line);

  // The pointer took hold of a row to drag it: the rows of the selection it is part of, or that
  // row alone, which is then selected. How many rows the drag carries.
  std::size_t grab(View& view, const State& state, const Context& context, const Pick& pick);

  // Files of the machine the window runs on are dragged in from outside the explorer: they are
  // held as rows dragged are, to be let go on a directory, where they are copied. Nothing is
  // known of them but their paths, so their runtime is asked what each is before a plan shows.
  // How many it holds: none when the mode takes no drag, or the window names no machine as its own.
  std::size_t bringIn(View& view, const Context& context, std::span<const std::string_view> paths);

  // What letting the rows go at `drop` would do.
  [[nodiscard]] Aim aim(const View& view, const State& state, const Context& context, const Drop& drop);

  // The rows dragged were let go at `drop`: they go in the directory there as `dd` or `yy` and
  // then `p` would put them, a change to write. And let go where nothing takes them.
  void drop(View& view, const State& state, const Context& context, const Drop& drop);
  void release(View& view) noexcept;

  // The rows dragged were let go over the pane `pane`, which takes them as Enter would give
  // them to it: paths typed at a shell, a mention to an agent, files opened in an editor.
  [[nodiscard]] Action hand(View& view, const State& state, const Context& context, std::uint64_t pane);

  // The explorer stands beside the panes or over them, as `<C-w>T` asks; and beside them it
  // takes the keys or leaves them to the panes.
  void pin(View& view, bool pinned) noexcept;
  void focus(View& view, bool focused) noexcept;

  // A side of the explorer, as the keys that move between panes name one.
  enum class Side : std::uint8_t {
    left,
    right,
    up,
    down,
  };

  // The key that moves between panes was pressed in the explorer, which stands to the right of
  // them: it goes to the explorer's window on that side. False when the panes are what is on
  // that side, and they take the keys.
  bool toward(View& view, Side side) noexcept;

  // A window shows `rows` rows; and the wheel moves what it shows by `rows` rows.
  void resize(View& view, const WindowRows& shown) noexcept;
  void scroll(View& view, const WindowRows& moved) noexcept;

  // The runtime of `machine` ended a plan, an undo or a commit: what the status line says of it,
  // and the changes that were written are no longer pending.
  void settle(View& view, const State& state, const Context& context, std::uint64_t machine);

  // The operations of the plan that shows, for the runtime of `machine`: how many `output` now
  // holds. They view the plan.
  using Operations = ds::Array<FileOperation, FileLimits::maximum_operations>;

  [[nodiscard]] std::size_t operations(tbc::ref_a<View> view, std::uint64_t machine, tbc::mut_a<Operations> output) noexcept;

}
