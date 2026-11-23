// The explorer: the files of a machine listed as a tree a person moves in with Neovim's keys,
// edits as text and hands to the panes. The listing is a buffer: a rename, a removal, a new entry
// or a paste is a change typed but not written, and `:w` shows the plan the runtime applies.
export module telar.gui.features.explorer;

export import :cache;
export import :files;
export import :keys;
export import :presentation;
export import :view;

import std;

import telar.base.ds;
import telar.tbc;
import telar.wire.files;

export namespace telar::gui::features::explorer {

  // Opens the explorer with one window, on the machine `machine` and at the focused pane.
  void open(View& view, const State& state, const Context& context, std::uint64_t machine);

  void close(View& view) noexcept;

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

  // Escape: leaves the mode, the selection or the filter.
  void cancel(View& view, const State& state, const Context& context);

  // The pointer chose a row of a window: alone, up to it from the selection, or beside the ones
  // picked.
  void select(View& view, const State& state, const Context& context, const Pick& pick);

  // The pointer asked for what Enter does on a row; and to fold or unfold a directory.
  [[nodiscard]] Action activate(View& view, State& state, const Context& context, const Pick& pick);
  void toggle(View& view, const State& state, const Context& context, const Pick& pick);

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
