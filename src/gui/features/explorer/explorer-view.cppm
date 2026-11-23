// What a window of telar shows of the explorer: its windows, each on a directory of a machine,
// the rows each lists, the changes typed but not written, and the mode the keys are read in.
export module telar.gui.features.explorer:view;

import std;

import :cache;
import :keys;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.ds;
import telar.tbc;
import telar.wire.files;

export namespace telar::gui::features::explorer {

  struct ViewLimits {
    // The windows the explorer splits into.
    static constexpr std::size_t windows = 3;
    // The changes it keeps typed but not written, and the times `u` takes one back.
    static constexpr std::size_t edits = FileLimits::maximum_operations;
    static constexpr std::size_t history = 64;
    static constexpr std::size_t jumps = 32;
    static constexpr std::size_t marks = 52;
    static constexpr std::size_t message_bytes = 512;
    // The lines of a diff a row unfolds below itself.
    static constexpr std::size_t diff_lines = 40;
    // How deep a tree unfolds.
    static constexpr std::size_t depth = 48;
    // The rows of a window before the client says how many fit.
    static constexpr std::uint16_t page = 20;
  };

  enum class Lens : std::uint8_t {
    tree,
    changes,
    panes,
  };

  inline constexpr std::size_t lens_count = 3;

  // Where a window that follows the focused pane roots itself: at the pane's directory, at the
  // workspace's, or at the home of the machine.
  enum class Scope : std::uint8_t {
    pane,
    workspace,
    machine,
  };

  enum class Mode : std::uint8_t {
    normal,
    visual,
    // A row's name is being typed: a rename, or a new entry.
    insert,
    search,
    command,
    // The plan of `:w` shows, and waits for a yes.
    plan,
    help,
  };

  enum class Sort : std::uint8_t {
    name,
    size,
    modified,
  };

  enum class Tone : std::uint8_t {
    info,
    error,
    ask,
  };

  // What a pane of the tab is to the explorer, which decides what Enter does with a file there.
  enum class PaneKind : std::uint8_t {
    shell,
    agent,
    editor,
    program,
  };

  struct PaneFact {
    std::uint64_t id = 0;
    // Its place in the tab, from one.
    std::uint16_t number = 0;
    PaneKind kind = PaneKind::shell;
    std::string_view title;
    std::string_view cwd;
  };

  // What the explorer reads of the session it is driven with: the panes of the tab that shows,
  // the workspace's directory, and the machine.
  struct Context {
    std::span<const PaneFact> panes;
    std::uint64_t focused = 0;
    std::string_view workspace;
    std::string_view home;
    std::string_view machine;
    bool local = true;
  };

  enum class RowKind : std::uint8_t {
    // An entry of a directory the window holds.
    entry,
    // An entry a change not written adds: a new file, or what a paste brings.
    added,
    // A group's title in the changes, and a note that more entries exist than are listed.
    header,
    note,
    // A line of a diff unfolded below its file.
    diff,
    // A changed path of the repository, in the changes lens.
    change,
    // A pane of the tab, in the panes lens.
    pane,
  };

  enum class DiffTone : std::uint8_t {
    context,
    added,
    removed,
    hunk,
  };

  // What a line of a diff is, by how it starts.
  [[nodiscard]] DiffTone toneOf(std::string_view line) noexcept;

  struct Row {
    RowKind kind = RowKind::entry;
    std::uint8_t depth = 0;
    bool directory = false;
    bool expanded = false;
    DiffTone tone = DiffTone::context;
    // An entry: the directory of the machine's cache that holds it, and its place there.
    std::uint32_t holder = 0;
    std::uint32_t entry = 0;
    // Another row: its text among the window's, and what it stands for: the change of the
    // repository, the pane of the context, or the id of the change that adds it.
    std::uint32_t text = 0;
    std::uint32_t text_size = 0;
    std::uint32_t item = 0;
    // An entry's size against the largest beside it, in thousandths.
    std::uint16_t share = 0;
  };

  enum class EditKind : std::uint8_t {
    rename,
    remove,
    create,
    paste,
    restore,
  };

  enum class PasteKind : std::uint8_t {
    move,
    copy,
  };

  // A change typed but not written, as a line edited in a buffer is before `:w`.
  struct Edit {
    explicit Edit(Memory& memory);

    std::uint32_t id = 0;
    EditKind kind = EditKind::rename;
    PasteKind paste = PasteKind::copy;
    bool directory = false;
    std::uint64_t machine = 0;
    // The path a rename, a removal or a restore changes; the directory a new entry or a paste
    // goes in.
    ds::String<Memory> path;
    // The name a rename gives, or the one of what is added.
    ds::String<Memory> name;
    // Where a paste comes from, and on which machine.
    ds::String<Memory> source;
    std::uint64_t source_machine = 0;
    FileIdentity identity{};
    std::uint64_t size = 0;

    // A copy that keeps its texts in `memory`, and borrows nothing of this one.
    [[nodiscard]] tbc::val_a<Edit> clone(tbc::mut_a<Memory> memory) const;
  };

  // What `yy` or `dd` took, for `p` to put.
  struct Yanked {
    explicit Yanked(Memory& memory);

    std::uint64_t machine = 0;
    ds::String<Memory> path;
    bool directory = false;
    FileIdentity identity{};
    std::uint64_t size = 0;
  };

  enum class PlanVerb : std::uint8_t {
    create,
    move,
    copy,
    remove,
    restore,
    // What `ga` and `gu` ask at once, without a plan to confirm.
    stage,
    unstage,
  };

  // One line of the plan `:w` shows: what the runtime will be asked to do.
  struct PlanStep {
    explicit PlanStep(Memory& memory);

    PlanVerb verb = PlanVerb::create;
    bool directory = false;
    std::uint64_t machine = 0;
    ds::String<Memory> source;
    ds::String<Memory> target;
    FileIdentity identity{};
    std::uint64_t size = 0;
  };

  // A place the explorer was, to go back to: a mark, or a step of the jump list.
  struct Place {
    explicit Place(Memory& memory);

    Notation letter;
    std::uint64_t machine = 0;
    ds::String<Memory> root;
    ds::String<Memory> selected;
  };

  // One window of the explorer: a directory of a machine, what it lists and how.
  struct Window {
    explicit Window(Memory& memory);

    // The machine whose files it shows, as whoever drives the explorer names it.
    std::uint64_t machine = 0;
    ds::String<Memory> root;
    Lens lens = Lens::tree;
    Scope scope = Scope::workspace;
    bool follow = true;
    bool hidden = false;
    bool ignored = false;
    Sort sort = Sort::name;
    ds::String<Memory> filter;
    // The directories unfolded, and the files whose diff shows below them.
    ds::Vec<ds::String<Memory>, Memory> expanded;
    ds::Vec<ds::String<Memory>, Memory> diffs;
    ds::Vec<Row, Memory> rows;
    ds::Vec<char, Memory> text;
    // The row selected, and its path, which a new listing finds it by.
    std::size_t cursor = 0;
    // The first row the window shows: it draws `page` rows from there.
    std::size_t top = 0;
    ds::String<Memory> selected;
    // Where a visual selection started.
    ds::Option<std::size_t> anchor;
    // The rows picked one by one with the pointer.
    ds::Vec<std::uint32_t, Memory> picked;
    // How many rows, from the selected one, the command that runs takes: the count of `3dd`.
    std::uint32_t reach = 1;
    // The entries of the root the listing leaves out, and what the root holds.
    std::uint32_t hidden_entries = 0;
    std::uint32_t ignored_entries = 0;
    std::uint64_t bytes = 0;
    // The rows that fit, for half a page.
    std::uint16_t page = ViewLimits::page;
    // Whether the root's listing is yet to arrive.
    bool loading = false;
    // The pane it last followed and where that pane was, to follow again only when either moves.
    std::uint64_t followed = 0;
    ds::String<Memory> followed_cwd;
  };

  // What the keys asked of the panes or of the runtime, for whoever drives the explorer to do.
  enum class ActionKind : std::uint8_t {
    none,
    close,
    // Type `text` at the pane; mention it to the agent there.
    insert,
    mention,
    // Open the paths in the tab's editor.
    open,
    // Change the pane's shell to the directory in `text`.
    change_directory,
    // Split the tab with a shell in the directory in `text`.
    split,
    // Put `text` on the clipboard.
    copy,
    focus_pane,
    // Send the plan, take the last one back, or commit with the message in `text`.
    apply,
    undo,
    commit,
  };

  struct Action {
    ActionKind kind = ActionKind::none;
    std::uint64_t pane = 0;
    bool overwrite = false;
  };

  struct View {
    explicit View(Memory& made_in);

    Memory& memory;
    bool open = false;
    // Whether the explorer stays open after it hands a file to a pane; and whether the windows
    // stand side by side.
    bool pinned = false;
    bool side_by_side = true;
    ds::Vec<ds::Box<Window, Memory>, Memory> windows;
    std::size_t current = 0;
    Mode mode = Mode::normal;
    Keys keys;
    // The changes typed but not written, and what they were before each of the last ones.
    ds::Vec<Edit, Memory> edits;
    ds::Vec<ds::Vec<Edit, Memory>, Memory> history;
    std::uint32_t next_edit = 1;
    ds::Vec<Yanked, Memory> yanked;
    PasteKind yank = PasteKind::copy;
    ds::Vec<Place, Memory> marks;
    ds::Vec<Place, Memory> jumps;
    std::size_t jump = 0;
    // The name being typed in insert mode: of the change `inserting`, or a rename of the row
    // selected when it is 0; and what the field starts with.
    std::uint32_t inserting = 0;
    ds::String<Memory> draft;
    // What the command line starts with.
    ds::String<Memory> prefill;
    ds::Vec<PlanStep, Memory> plan;
    bool overwrite = false;
    // Whether the plan in flight is the one of the changes typed, which end with it.
    bool writing = false;
    runtime::FixedText<ViewLimits::message_bytes> message;
    Tone tone = Tone::info;
    // What an action hands over: its text, and the paths it is about.
    ds::String<Memory> text;
    ds::Vec<ds::String<Memory>, Memory> paths;
    // The command `.` repeats.
    Command last = Command::none;
    // Grows with every change to what the explorer shows.
    std::uint64_t revision = 0;
    // The cache's revision and settled count the rows were last built from.
    std::uint64_t built = 0;
    // The previews of the cache the explorer last showed.
    std::uint64_t previewed = 0;
    std::uint64_t settled = 0;
  };

  [[nodiscard]] const Window& window(const View& view) noexcept;

  // The change of `kind` typed on `path` of `machine`, if there is one.
  [[nodiscard]] tbc::val_a<const Edit*> editOn(tbc::ref_a<View> view, EditKind kind, std::uint64_t machine, std::string_view path) noexcept;

  // The change that adds the row, for a row a change adds.
  [[nodiscard]] tbc::val_a<const Edit*> editOf(tbc::ref_a<View> view, const Row& row) noexcept;

  // A row of a window, as the pointer or the client names it, and how choosing it adds to the
  // selection: up to it from the selected one, or beside the ones picked.
  struct Pick {
    std::size_t window = 0;
    std::size_t row = 0;
    bool extend = false;
    bool toggle = false;
  };

  // Rows of a window, counted: how many it shows, or by how many the wheel moves what it shows.
  struct WindowRows {
    std::size_t window = 0;
    std::int64_t count = 0;
  };

  // The rows a command acts on: the visual selection, else the ones picked, else the selected one
  // and as many after it as the command's count says.
  struct Range {
    std::size_t first = 0;
    std::size_t last = 0;
    bool visual = false;
  };

  [[nodiscard]] Range range(const View& view, const Window& window) noexcept;
  [[nodiscard]] bool chosen(const View& view, const Window& window, std::size_t row) noexcept;

  // The absolute path of a row that names one; empty for a title, a note or a line of a diff.
  void pathOf(ds::String<Memory>& path, const Window& window, const State& state, const Context& context, const Row& row);

  // The row's name as it lists: the entry's, the one a change gives it, or the row's own text.
  [[nodiscard]] tbc::val_a<std::string_view> nameOf(tbc::ref_a<Window> window, tbc::ref_a<State> state, const Row& row) noexcept;

}
