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
import telar.tbc;
import telar.wire.files;

export namespace telar::gui::features::explorer {

  // What the window writes is copied out of what the session and the view hold, so nothing it
  // was given has to outlive the call: a name or a line is cut to what a row shows.
  inline constexpr std::size_t short_text_bytes = 48;
  inline constexpr std::size_t line_text_bytes = 512;
  using ShortText = runtime::FixedText<short_text_bytes>;
  using LineText = runtime::FixedText<line_text_bytes>;
  // A word the explorer itself spells: the name of a mode, the keys of a hint.
  using Word = tbc::val_static<std::string_view>;

  // An amount of bytes in at most five cells, in powers of 1024: 512B, 7.6K, 108K, 2.5M, 100G.
  [[nodiscard]] ShortText bytes(std::uint64_t value);

  // How long ago `then` was, seen from `now`, both in seconds: 5 min, 17 h, 3 d.
  [[nodiscard]] ShortText age(std::uint64_t then, std::uint64_t now);

  // A day as a commit's date reads: 2026-11-08.
  [[nodiscard]] ShortText day(std::uint64_t seconds);

  // `path` with the home directory written as `~`.
  [[nodiscard]] tbc::val_a<std::string_view> withoutHome(tbc::val_a<std::string_view> path, std::string_view home, bool& shortened) noexcept;

  // The directory a path is in, and its name there.
  [[nodiscard]] std::string_view parentOf(std::string_view path) noexcept;
  [[nodiscard]] std::string_view baseOf(std::string_view path) noexcept;

  // Whether `path` is `directory` or below it.
  [[nodiscard]] bool within(std::string_view path, std::string_view directory) noexcept;

  // Appends to `text` the path a person would type at a shell in `cwd`: relative when it is no
  // more than two directories up, with `~` under the home otherwise, and quoted when the shell
  // would split or expand it.
  // Who reads a path that is typed: the directory it reads it from, the home of its account,
  // and whether it is a shell, which splits a word at a space unless it is quoted.
  struct Reader {
    std::string_view cwd;
    std::string_view home;
    bool shell = true;
  };

  void appendTyped(ds::String<Memory>& text, std::string_view path, const Reader& reader);

  // What a row shows beside its name.
  // Whose hand a touch is by, for the color of its chip: the person at a pane, the agents the
  // window has a color for, and any other agent.
  enum class ActorTone : std::uint8_t {
    you,
    claude,
    codex,
    agent,
  };

  // The chip of who touched a file: `you`, or the place in the tab of the pane its agent runs in.
  struct ActorLook {
    ActorTone tone = ActorTone::you;
    ShortText chip;
  };

  inline constexpr std::size_t actor_capacity = 3;

  // How the editors hold a file: in a buffer, and in one with changes that were not written.
  enum class Hold : std::uint8_t {
    none,
    open,
    unsaved,
  };

  // What the editors of a machine hold of a file, and the pane of the one that holds it so: one
  // with changes not written before any other.
  struct Held {
    Hold hold = Hold::none;
    std::uint64_t pane = 0;
  };

  // A file of a machine, by its path there.
  struct Located {
    std::uint64_t machine = 0;
    std::string_view path;
  };

  [[nodiscard]] Held heldBy(const Edited& edited, const Located& file);

  // Whether a buffer with changes not written shows the file, or one below it.
  [[nodiscard]] bool unsavedIn(const Edited& edited, const Located& file);

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
    // It is a file arriving from another machine: its size says how much of it did.
    bool arriving = false;
    // The name, and before it, in a flat list, the path that leads to it.
    LineText lead;
    LineText name;
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
    // Who touched it lately, the last one first.
    ds::Array<ActorLook, actor_capacity> actors{};
    std::uint8_t actor_count = 0;
    // Whether an editor of its machine has it in a buffer.
    Hold editor = Hold::none;
    // In the lens of touches: with which command or tool, and how long ago.
    ShortText verb;
    ShortText ago;
  };

  [[nodiscard]] RowLook look(const View& view, const State& state, const Context& context, const Pick& pick);

  // The head of a window: the machine, the root with its last directory apart, and the branch.
  struct HeaderLook {
    LineText machine;
    bool local = true;
    // The machine is not connected: what the window lists is what it last said.
    bool away = false;
    // The root up to its last directory, with the home written as `~`, and that directory.
    LineText lead;
    LineText last;
    bool repository = false;
    LineText branch;
    // How far the branch is from its base, `↑6 main`: empty with no base, and on the base
    // itself with nothing ahead of it.
    LineText distance;
    std::uint32_t staged = 0;
    std::uint32_t unstaged = 0;
    std::uint32_t untracked = 0;
  };

  [[nodiscard]] HeaderLook header(const View& view, const State& state, const Context& context, std::size_t window);

  // The status line of a window, as Neovim's: the mode, what it follows, the root, what it
  // leaves out, what the root holds and where the selection is.
  struct StatusLook {
    Word mode;
    Mode kind = Mode::normal;
    bool current = false;
    // `[3 zsh]` while it follows the focused pane, `[fixed]` otherwise; `[stale]` while its
    // machine is not connected, whatever it followed.
    ShortText following;
    bool follows = false;
    // `box:` before the root of a window on another machine than the one the window runs on.
    ShortText machine;
    LineText root;
    bool pending = false;
    // `[size↓ . !]`: the sort, and the hidden and ignored entries it lists.
    ShortText flags;
    // `/usage 3`: the filter, and how many paths below the root match it; `50+` when more match
    // than are listed, and `…` while the runtime still searches.
    LineText filter;
    ShortText total;
    // The keys typed toward a command, as `showcmd` shows them.
    ShortText keys;
    std::uint32_t chosen = 0;
    std::uint32_t position = 0;
    std::uint32_t count = 0;
    // The files on the way to or from the window's machine.
    std::uint32_t carried = 0;
  };

  [[nodiscard]] StatusLook status(const View& view, const State& state, const Context& context, std::size_t window);

  // A key and what it does now, for the line of hints.
  // The keys a hint or a line of the menu teaches, as the map has them.
  using KeysText = runtime::FixedText<pending_bytes>;

  struct Hint {
    KeysText keys;
    LineText label;
    bool enabled = true;
  };

  // As many as normal mode shows at most: with changes to write, rows yanked, and beside the panes.
  inline constexpr std::size_t hint_capacity = 16;

  struct Hints {
    ds::Array<Hint, hint_capacity> items{};
    std::size_t count = 0;
  };

  [[nodiscard]] Hints hints(const View& view, const State& state, const Context& context);

  // A line of the help: the group it is listed under, the keys that do it as the map has them,
  // none for a command no key names, and what they do.
  inline constexpr std::size_t help_keys_bytes = 64;
  inline constexpr std::size_t help_lines = 65;

  struct HelpLine {
    Word group;
    runtime::FixedText<help_keys_bytes> keys;
    Word label;
  };

  struct Help {
    ds::Array<HelpLine, help_lines> lines{};
    std::size_t count = 0;
  };

  [[nodiscard]] Help help(const View& view);

  // The lenses of the current window, each with how many rows it would list.
  struct LensLook {
    Word name;
    std::uint32_t count = 0;
    bool counted = false;
    bool current = false;
  };

  [[nodiscard]] ds::Array<LensLook, lens_count> lenses(const View& view, const State& state, const Context& context);

  // A fact of the preview: what it is, and its value in two parts, the second one dimmer.
  struct Fact {
    Word label;
    LineText value;
    LineText detail;
    // The lines a change adds and removes, shown after the value.
    std::uint32_t added = 0;
    std::uint32_t removed = 0;
  };

  inline constexpr std::size_t fact_capacity = 8;

  // A touch of the selected file, in the preview: who, from which pane, how and how long ago.
  struct ActivityLook {
    ActorLook actor;
    LineText who;
    ShortText verb;
    ShortText ago;
  };

  inline constexpr std::size_t activity_capacity = 4;

  // The preview of the selected row: its name and path, what is known of it, the panes that are
  // in it, and its diff or the head of its text.
  // One of the heaviest entries of the directory the preview shows: its name, its size, and its
  // part of what the directory holds, in hundredths.
  struct HeavyLook {
    LineText name;
    // Why the window does not list it unless asked: `hidden`, `ignored`, or nothing.
    Word tag;
    ShortText size;
    std::uint8_t share = 0;
    bool directory = false;
  };

  inline constexpr std::size_t heavy_capacity = 7;

  struct PreviewLook {
    bool shown = false;
    bool directory = false;
    // What the row is: a pane and an entry not written yet have no file to show an icon of.
    RowKind kind = RowKind::entry;
    LineText name;
    LineText path;
    ds::Array<Fact, fact_capacity> facts{};
    std::size_t fact_count = 0;
    ds::Array<std::uint16_t, 4> panes{};
    std::uint8_t pane_count = 0;
    // The last touches of the file, the newest first.
    ds::Array<ActivityLook, activity_capacity> activity{};
    std::uint8_t activity_count = 0;
    // The heaviest of what a directory holds, the heaviest first: none until all of it is
    // measured, since a list made before would name the wrong ones.
    ds::Array<HeavyLook, heavy_capacity> heavy{};
    std::uint8_t heavy_count = 0;
    // The title over the text, and whether the text is a diff or the file's head.
    Word title;
    bool diff = false;
    bool waiting = false;
    // What is worth knowing of a row that is no file yet, or is a pane: said under its facts.
    Word note;
  };

  [[nodiscard]] PreviewLook preview(const View& view, const State& state, const Context& context, std::uint64_t now_seconds);

  // The text the preview shows: the diff of the selected file, or its head. It is the session's
  // own, not copied: a diff is as long as a screen.
  [[nodiscard]] tbc::val_a<std::string_view> previewText(const View& view, tbc::ref_a<State> state) noexcept;

  // A line of the menu that shows: what it does, the keys that do the same, and a rule in the
  // place of one that parts two groups.
  struct MenuLine {
    LineText label;
    KeysText keys;
    bool enabled = true;
    bool rule = false;
    bool current = false;
  };

  struct MenuLook {
    ds::Array<MenuLine, Menu::lines> lines{};
    std::size_t count = 0;
  };

  // The menu of the row it opened on; no line while none shows.
  [[nodiscard]] MenuLook menu(const View& view, const State& state, const Context& context);

  // A file on its way between two machines, as the explorer lists it under its windows.
  struct TransferLook {
    std::uint32_t id = 0;
    LineText name;
    // `box → macbook`.
    LineText route;
    // `1.2M of 4.0M`, how much of it arrived in thousandths, and `3.1M/s` while it runs.
    ShortText progress;
    std::uint16_t share = 0;
    ShortText rate;
    // What it does now, or how it ended.
    Word phase;
    bool ended = false;
    bool failed = false;
  };

  inline constexpr std::size_t transfer_lines = 4;

  struct TransferLooks {
    ds::Array<TransferLook, transfer_lines> items{};
    std::size_t count = 0;
    // The ones that do not fit the lines.
    std::size_t more = 0;
  };

  // The transfers the explorer shows, the ones that run first.
  [[nodiscard]] TransferLooks transfers(const View& view, const Context& context, std::uint64_t now_ms);

  // The verb of a step of the plan, as it reads: CREATE, MOVE, COPY, DELETE, RESTORE.
  [[nodiscard]] std::string_view verbText(PlanVerb verb) noexcept;

  // What a line of the plan says after its paths: the size of what it changes, when the window
  // knows it, and what the person should know before a yes.
  struct PlanNote {
    ShortText size;
    LineText warning;
    // What the line does besides what its verb says: a transfer between machines, the trash a
    // delete goes to, what a restore discards.
    LineText note;
  };

  // Whether an agent touched the file a step reads after the time its listing gave it. `state`
  // is the cache of the machine that file is on.
  [[nodiscard]] bool touchedSince(const State& state, const PlanStep& step) noexcept;

  // What the window knows of the file a step changes that the listings do not say: what
  // `touchedSince` said of its source, and the files the editors hold.
  struct PlanSeen {
    bool touched = false;
    Edited edited;
    // The label of the machine the step changes, and of the one it carries from, if any.
    std::string_view machine;
    std::string_view source;
  };

  // `state` is the cache of the machine the step changes, whose listings say whether the name
  // it goes to is taken.
  [[nodiscard]] PlanNote planNote(const View& view, const State& state, const PlanStep& step, const PlanSeen& seen);

  // The name of a mode on the status line.
  [[nodiscard]] std::string_view modeText(Mode mode) noexcept;

  // What the line under the windows says while the explorer has nothing else to say.
  inline constexpr std::string_view idle_message = "? shows the keys · /, : and V as in Neovim";

  // What the runtimes did with the plan last sent, for the status line: what was applied, what
  // was skipped, and how many machines have yet to say.
  [[nodiscard]] LineText outcomeText(const Written& written, std::size_t waiting);

}
