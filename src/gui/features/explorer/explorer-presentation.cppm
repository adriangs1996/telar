// What the window writes of the explorer: sizes, ages and paths as a person reads them, and for
// each row, header, status line and preview the texts and marks the window places.
export module telar.gui.features.explorer:presentation;

import std;

import :cache;
import :keys;
import :view;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.ds;
import telar.wire.files;

export namespace telar::gui::features::explorer {

  inline constexpr std::size_t short_text_bytes = 48;
  inline constexpr std::size_t line_text_bytes = 512;
  using ShortText = runtime::FixedText<short_text_bytes>;
  using LineText = runtime::FixedText<line_text_bytes>;

  // An amount of bytes in at most five cells, in powers of 1024: 512B, 7.6K, 108K, 2.5M, 100G.
  [[nodiscard]] ShortText bytes(std::uint64_t value);

  // How long ago `then` was, seen from `now`, both in seconds: 5 min, 17 h, 3 d.
  [[nodiscard]] ShortText age(std::uint64_t then, std::uint64_t now);

  // A day as a commit's date reads: 2026-11-08.
  [[nodiscard]] ShortText day(std::uint64_t seconds);

  // `path` with the home directory written as `~`.
  [[nodiscard]] std::string_view withoutHome(std::string_view path, std::string_view home, bool& shortened) noexcept;

  // The directory a path is in, and its name there.
  [[nodiscard]] std::string_view parentOf(std::string_view path) noexcept;
  [[nodiscard]] std::string_view baseOf(std::string_view path) noexcept;

  // Whether `path` is `directory` or below it.
  [[nodiscard]] bool within(std::string_view path, std::string_view directory) noexcept;

  // Appends to `text` the path a person would type at a shell in `cwd`: relative when it is no
  // more than two directories up, with `~` under the home otherwise, and quoted when the shell
  // would split or expand it.
  void appendTyped(ds::String<Memory>& text, std::string_view path, std::string_view cwd, std::string_view home, bool quote);

  // What a row shows beside its name.
  struct RowLook {
    RowKind kind = RowKind::entry;
    std::uint8_t depth = 0;
    DiffTone tone = DiffTone::context;
    bool directory = false;
    bool expanded = false;
    bool selected = false;
    // In the visual selection, or picked with the pointer.
    bool marked = false;
    bool ignored = false;
    // What a change not written does to it: removes it, renames it, or adds it.
    bool removed = false;
    bool renamed = false;
    bool added = false;
    // The name, and before it, in a flat list, the path that leads to it.
    std::string_view lead;
    std::string_view name;
    // What git's index holds of it, and what the working tree does.
    FileState staged = FileState::unchanged;
    FileState unstaged = FileState::unchanged;
    // The changed paths below a directory, and the lines a change adds and removes.
    std::uint32_t below = 0;
    std::uint32_t lines_added = 0;
    std::uint32_t lines_removed = 0;
    // Its size, and its share of the largest beside it, in thousandths. A directory not measured
    // yet has neither.
    ShortText size;
    std::uint16_t share = 0;
    bool measured = true;
    bool partial = false;
    // The letters of the marks set on it, and the panes whose shell is in it.
    ShortText marks;
    ds::Array<std::uint16_t, 4> panes{};
    std::uint8_t pane_count = 0;
    // What a change not written says of it.
    LineText note;
  };

  [[nodiscard]] RowLook look(const View& view, const State& state, const Context& context, std::size_t window, std::size_t row);

  // The head of a window: the machine, the root with its last directory apart, and the branch.
  struct HeaderLook {
    std::string_view machine;
    bool local = true;
    // The root up to its last directory, with the home written as `~`, and that directory.
    LineText lead;
    std::string_view last;
    bool repository = false;
    std::string_view branch;
    bool upstream = false;
    std::uint32_t ahead = 0;
    std::uint32_t behind = 0;
    std::uint32_t staged = 0;
    std::uint32_t unstaged = 0;
    std::uint32_t untracked = 0;
  };

  [[nodiscard]] HeaderLook header(const View& view, const State& state, const Context& context, std::size_t window);

  // The status line of a window, as Neovim's: the mode, what it follows, the root, what it
  // leaves out, what the root holds and where the selection is.
  struct StatusLook {
    std::string_view mode;
    Mode kind = Mode::normal;
    bool current = false;
    // `[3 zsh]` while it follows the focused pane, `[pinned]` otherwise.
    ShortText following;
    bool follows = false;
    LineText root;
    bool pending = false;
    // `[size↓ . !]`: the sort, and the hidden and ignored entries it lists.
    ShortText flags;
    ShortText total;
    // The keys typed toward a command, as `showcmd` shows them.
    ShortText keys;
    std::uint32_t chosen = 0;
    std::uint32_t position = 0;
    std::uint32_t count = 0;
  };

  [[nodiscard]] StatusLook status(const View& view, const State& state, const Context& context, std::size_t window);

  // A key and what it does now, for the line of hints.
  struct Hint {
    std::string_view keys;
    LineText label;
    bool enabled = true;
  };

  inline constexpr std::size_t hint_capacity = 14;

  struct Hints {
    ds::Array<Hint, hint_capacity> items{};
    std::size_t count = 0;
  };

  [[nodiscard]] Hints hints(const View& view, const State& state, const Context& context);

  // The lenses of the current window, each with how many rows it would list.
  struct LensLook {
    std::string_view name;
    std::uint32_t count = 0;
    bool counted = false;
    bool current = false;
  };

  [[nodiscard]] ds::Array<LensLook, lens_count> lenses(const View& view, const State& state, const Context& context);

  // A fact of the preview: what it is, and its value in two parts, the second one dimmer.
  struct Fact {
    std::string_view label;
    LineText value;
    LineText detail;
    // The lines a change adds and removes, shown after the value.
    std::uint32_t added = 0;
    std::uint32_t removed = 0;
  };

  inline constexpr std::size_t fact_capacity = 6;

  // The preview of the selected row: its name and path, what is known of it, the panes that are
  // in it, and its diff or the head of its text.
  struct PreviewLook {
    bool shown = false;
    bool directory = false;
    std::string_view name;
    LineText path;
    ds::Array<Fact, fact_capacity> facts{};
    std::size_t fact_count = 0;
    ds::Array<std::uint16_t, 4> panes{};
    std::uint8_t pane_count = 0;
    // The title over the text, and the text: a diff when `diff`, else the file's head.
    std::string_view title;
    std::string_view text;
    bool diff = false;
    bool waiting = false;
  };

  [[nodiscard]] PreviewLook preview(const View& view, const State& state, const Context& context, std::uint64_t now_seconds);

  // The verb of a step of the plan, as it reads: CREATE, MOVE, COPY, DELETE, RESTORE.
  [[nodiscard]] std::string_view verbText(PlanVerb verb) noexcept;

  // The name of a mode on the status line.
  [[nodiscard]] std::string_view modeText(Mode mode) noexcept;

  // What the line under the windows says while the explorer has nothing else to say.
  inline constexpr std::string_view idle_message = "? shows the keys · /, : and V as in Neovim";

  // What the last plan did, as the status line says it: how many operations were applied, and
  // how many were skipped and why.
  [[nodiscard]] LineText outcomeText(const State& state);

}
