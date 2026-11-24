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
import telar.wire.vocabulary;

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
    // The bytes of a filter the runtime searches for: what its path search takes.
    static constexpr std::size_t query_bytes = 64;
    // The names `<Tab>` lists when several complete a path.
    static constexpr std::size_t candidates = 12;
  };

  enum class Lens : std::uint8_t {
    tree,
    changes,
    // The files the panes touched lately, the newest first.
    touched,
    panes,
  };

  inline constexpr std::size_t lens_count = 4;

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
    // The menu of a row shows, and takes the keys.
    menu,
    // A question waits for a yes: whether to bring a copy of a file from another machine.
    question,
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

  // How the window reaches a machine: its runtime answers for files, it is not connected, or it
  // is connected to a runtime that knows nothing of them.
  enum class Reach : std::uint8_t {
    answers,
    away,
    silent,
  };

  // A machine the window keeps, for a command that names one or goes to the next.
  struct MachineFact {
    std::uint64_t id = 0;
    std::string_view label;
    bool local = false;
    Reach reach = Reach::answers;
  };

  // A file a buffer of an editor pane shows, by the path its machine names it by: a piece of the
  // text of the `Edited` that lists it.
  struct EditedFile {
    std::uint64_t machine = 0;
    std::uint64_t pane = 0;
    std::uint32_t offset = 0;
    std::uint32_t size = 0;
    // The buffer has changes that were not written.
    bool modified = false;
  };

  // The files the editors of every machine hold in their buffers, as the window last saw them.
  struct Edited {
    std::string_view text;
    std::span<const EditedFile> files;
  };

  // A file to show in the explorer, or with no path the directory to show.
  struct Revealed {
    std::string_view path;
    std::string_view directory;
  };

  // What the explorer reads around the files of one machine, the host: the one whose cache a
  // use case is given, which is the machine of the window it acts on. The panes are the ones of
  // the tab that shows, which is of the machine `shown` and may be another.
  struct Context {
    std::span<const PaneFact> panes;
    std::uint64_t focused = 0;
    std::string_view workspace;
    // The host's home, its label, whether the window runs on it, and how the window reaches it.
    std::string_view home;
    std::string_view machine;
    bool local = true;
    // The time, in seconds, a row says how long ago something was against.
    std::uint64_t now = 0;
    Reach reach = Reach::answers;
    std::uint64_t host = 0;
    std::uint64_t shown = 0;
    std::span<const MachineFact> machines;
    Edited edited;
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
    // A path the runtime found below the root for the window's filter.
    match,
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
    // What a paste brings is a symbolic link: between machines it goes as what it says.
    bool link = false;
    // The file it changes is one no listing the window holds names, so the runtime is asked
    // what it is before the plan shows: the identity a plan carries is always one it read.
    bool unidentified = false;

    // A copy that keeps its texts in `memory`, and borrows nothing of this one.
    [[nodiscard]] tbc::val_a<Edit> clone(tbc::mut_a<Memory> memory) const;
  };

  // What `yy` or `dd` took, for `p` to put.
  struct Yanked {
    explicit Yanked(Memory& memory);

    std::uint64_t machine = 0;
    ds::String<Memory> path;
    bool directory = false;
    // A symbolic link, whatever it points to: it is taken as a link, and not as what it shows.
    bool link = false;
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
    // The machine a copy or a move comes from, when it is another than the one it goes to: the
    // window carries it there, and no runtime is asked for it as an operation. 0 otherwise.
    std::uint64_t source_machine = 0;
    // What it carries from that machine is a symbolic link.
    bool link = false;
  };

  // How a file goes from one machine to another: copied, moved, which sends the original to the
  // trash of its machine once the copy is whole, or brought to be typed at a pane.
  enum class TransferKind : std::uint8_t {
    copy,
    move,
    bring,
  };

  enum class TransferPhase : std::uint8_t {
    // More transfers run than the window carries at once.
    waiting,
    // Of a tree: a directory of it is made where it goes, then its listing is read where it
    // comes from.
    making,
    walking,
    // A chunk is read from the source, then written to the partial of the target.
    reading,
    writing,
    // Of a tree: a link of it, whose text was read, is made where it goes.
    linking,
    // The partial takes the target's name; the source of a move goes to the trash.
    placing,
    trashing,
    // What arrived is removed, after a failure or a cancel: the partial of a file, and of a
    // tree the directory it had made.
    dropping,
    clearing,
    arrived,
    failed,
    cancelled,
  };

  struct TreeLimits {
    // How deep a tree the window carries is, and how many entries it holds: past either it is
    // refused, with nothing of it left where it was going.
    static constexpr std::size_t depth = 32;
    static constexpr std::uint32_t entries = 50000;
  };

  // A file of the directory a tree's walk is in, still to carry.
  struct TreeFile {
    explicit TreeFile(Memory& memory);

    ds::String<Memory> name;
    FileIdentity identity{};
    std::uint64_t size = 0;
    // A symbolic link: what it says is read, and a link that says it is made where it goes.
    bool link = false;
  };

  // A file the window carries from one machine to another, a chunk at a time: the runtimes do
  // not talk to each other. It goes on while the explorer is closed. A directory is carried as
  // its tree, a directory at a time and a file at a time, as one transfer.
  struct Transfer {
    explicit Transfer(Memory& memory);

    std::uint32_t id = 0;
    TransferKind kind = TransferKind::copy;
    TransferPhase phase = TransferPhase::waiting;
    // The file, on the machine it is read from, as its listing named it.
    std::uint64_t from = 0;
    ds::String<Memory> source;
    FileIdentity identity{};
    // The machine, the directory and the name it arrives at. A file brought names no directory:
    // whoever drives the explorer says where that machine keeps what it brings.
    std::uint64_t to = 0;
    ds::String<Memory> directory;
    ds::String<Memory> name;
    bool overwrite = false;
    // The pane a file brought is typed at, and whether as a mention.
    std::uint64_t pane = 0;
    bool mention = false;
    bool handed = false;
    // How much of it had arrived when that was last shown.
    std::uint64_t shown = 0;
    // The plan it is of: what one plan brings to a machine goes back together.
    std::uint32_t batch = 0;
    // The partial the target's runtime named, and the path the file ended at.
    ds::String<Memory> partial;
    ds::String<Memory> placed;
    // How much arrived, of how much.
    std::uint64_t done = 0;
    std::uint64_t size = 0;
    // The chunk read and not yet written, and whether it is the file's last.
    ds::Vec<Byte, Memory> chunk;
    bool last = false;
    // The request in flight, 0 when none, and the connection of its machine it left on.
    std::uint64_t request = 0;
    std::uint64_t epoch = 0;
    // Asked to stop, which it does once no request of its is in flight; and why it did not arrive.
    bool stop = false;
    runtime::FixedText<ViewLimits::message_bytes> said;
    // When it started, when its progress last showed, and when it ended, in milliseconds.
    std::uint64_t started_ms = 0;
    std::uint64_t shown_ms = 0;
    std::uint64_t ended_ms = 0;
    // Of a tree. Its paths are from the tree's own directory: the directories still to walk,
    // the one the walk is in, the files of that one still to carry, and the one being carried,
    // for which `done`, `size`, `partial` and `chunk` above then stand.
    bool tree = false;
    ds::Vec<ds::String<Memory>, Memory> walk;
    ds::String<Memory> walked;
    ds::Vec<TreeFile, Memory> files;
    ds::String<Memory> file;
    FileIdentity file_identity{};
    // Whether what is read now is a symbolic link, of a tree or carried alone: it goes as what
    // it says.
    bool link = false;
    // Whether the listing of the directory the walk is in was asked for anew.
    bool fresh = false;
    // The directory the tree made where it goes, as the runtime named it; empty before.
    ds::String<Memory> root;
    // The bytes, the files and the links that arrived whole, of the ones the walk has seen so
    // far, and the special files it left out: a socket, a pipe or a device is not carried.
    std::uint64_t carried = 0;
    std::uint64_t seen = 0;
    std::uint32_t files_done = 0;
    std::uint32_t files_seen = 0;
    std::uint32_t links_done = 0;
    std::uint32_t entries_seen = 0;
    std::uint32_t left_out = 0;
  };

  // A file of another machine the keys asked to hand to a pane: the question waits for a yes.
  // A machine where a batch of transfers already changed something: what it changes next there
  // joins that change, and `u` takes both back together.
  struct Begun {
    std::uint32_t batch = 0;
    std::uint64_t machine = 0;

    friend bool operator==(const Begun&, const Begun&) = default;
  };

  struct Bringing {
    explicit Bringing(Memory& memory);

    std::uint64_t machine = 0;
    ds::String<Memory> path;
    FileIdentity identity{};
    std::uint64_t size = 0;
    std::uint64_t to = 0;
    std::uint64_t pane = 0;
    bool mention = false;
  };

  // A place the explorer was, to go back to: a mark, or a step of the jump list.
  struct Place {
    explicit Place(Memory& memory);

    Notation letter;
    std::uint64_t machine = 0;
    ds::String<Memory> root;
    ds::String<Memory> selected;
    // The label of its machine, for a place the runtime kept from another window whose machine
    // this window does not keep: `machine` is then 0, and the place goes nowhere.
    ds::String<Memory> away;
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
    // A path the selection goes to once its directory is listed: where `]a` is headed.
    ds::String<Memory> wanted;
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
    // Whether the rows are what the runtime found for the filter, not the tree.
    bool matching = false;
    // The pane it last followed and where that pane was, to follow again only when either moves.
    std::uint64_t followed = 0;
    ds::String<Memory> followed_cwd;
    // The revision of its machine's cache its rows were built from, and the previews of that
    // cache it last showed. A window that changed machine was built from none.
    static constexpr std::uint64_t unbuilt = std::numeric_limits<std::uint64_t>::max();
    std::uint64_t built = unbuilt;
    std::uint64_t previewed = 0;
    // The touches of its machine the rows and their chips were last drawn from.
    std::uint64_t touched = 0;
    // Whether its machine answered when the rows were built: one that comes or goes builds them again.
    Reach reached = Reach::answers;
  };

  // A line of the menu the pointer asks a row for. Each runs the command its key runs, so the
  // menu teaches the keys; a rule parts two groups of them.
  enum class MenuEntry : std::uint8_t {
    rule,
    hand,
    open,
    mention,
    rename,
    new_file,
    new_directory,
    cut,
    copy,
    paste,
    copy_relative,
    trash,
    shell_here,
    change_directory,
    window_here,
    diff,
    stage,
    unstage,
    discard,
    new_window,
    drop_change,
    write,
  };

  struct MenuItem {
    MenuEntry entry = MenuEntry::rule;
    bool enabled = true;
  };

  struct Menu {
    static constexpr std::size_t lines = 28;

    ds::Array<MenuItem, lines> items{};
    std::size_t count = 0;
    std::size_t current = 0;
    // The mode it opened over, which closing it gives back.
    Mode over = Mode::normal;
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
    // The machine whose files it is about: where the paths to open are, and whose repository
    // a commit is of.
    std::uint64_t machine = 0;
  };

  // What the runtimes did with the plan last sent, counted over every machine it went to.
  struct Written {
    std::uint32_t applied = 0;
    std::uint32_t renamed = 0;
    std::uint32_t stale = 0;
    std::uint32_t missing = 0;
    std::uint32_t refused = 0;
    // Whether it was taken back, and whether a machine says it still can be.
    bool undone = false;
    bool undoable = false;
  };

  // What a machine's cache had settled when the explorer last took it in.
  struct Settled {
    std::uint64_t machine = 0;
    std::uint64_t count = 0;
  };

  struct View {
    explicit View(Memory& made_in);

    Memory& memory;
    bool open = false;
    // Whether the explorer stands beside the panes, where it stays once it hands a file to one,
    // and not over them; and whether it takes the keys, which over the panes it always does.
    bool pinned = false;
    bool focused = true;
    // Whether the windows stand side by side.
    bool side_by_side = true;
    ds::Vec<ds::Box<Window, Memory>, Memory> windows;
    std::size_t current = 0;
    Mode mode = Mode::normal;
    Keys keys;
    // The keys the configuration leaves the explorer with.
    Keymap keymap;
    // The changes typed but not written, and what they were before each of the last ones.
    ds::Vec<Edit, Memory> edits;
    ds::Vec<ds::Vec<Edit, Memory>, Memory> history;
    std::uint32_t next_edit = 1;
    ds::Vec<Yanked, Memory> yanked;
    PasteKind yank = PasteKind::copy;
    // The rows the pointer drags, from when it took hold of one until it lets go.
    ds::Vec<Yanked, Memory> dragged;
    Menu menu;
    ds::Vec<Place, Memory> marks;
    ds::Vec<Place, Memory> jumps;
    std::size_t jump = 0;
    // Grows with every change to the marks or the jump list, and what it was when the runtime
    // was last given them: they outlive the window there.
    std::uint64_t places = 0;
    std::uint64_t places_kept = 0;
    // The name being typed in insert mode: of the change `inserting`, or a rename of the row
    // selected when it is 0; and what the field starts with.
    std::uint32_t inserting = 0;
    ds::String<Memory> draft;
    // What the command line starts with.
    ds::String<Memory> prefill;
    // The command line `<Tab>` completed last, and how many times it did: whoever shows the
    // line takes it when the count grows. And the line that waits for a directory to be listed.
    ds::String<Memory> completion;
    std::uint32_t completed = 0;
    ds::String<Memory> completing;
    ds::String<Memory> completing_in;
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
    // The machines the plan in flight went to and that have not answered, what the ones that
    // did answer did, and the machines the last plan changed, for `u` to take it back on each.
    ds::Vec<std::uint64_t, Memory> awaited;
    Written written;
    ds::Vec<std::uint64_t, Memory> wrote;
    ds::Vec<Settled, Memory> seen;
    // Where a window last was on each machine it left, to return there.
    ds::Vec<Place, Memory> visited;
    // The files carried between machines, the ones that wait and the ones that just ended; and
    // the one a question asks about.
    ds::Vec<Transfer, Memory> transfers;
    std::uint32_t next_transfer = 1;
    std::uint32_t next_batch = 1;
    ds::Vec<Begun, Memory> begun;
    Bringing bringing;
  };

  [[nodiscard]] const Window& window(const View& view) noexcept;

  // The label of the machine `id`, as the window names it.
  [[nodiscard]] tbc::val_a<std::string_view> labelOf(tbc::ref_a<Context> context, std::uint64_t id) noexcept;

  // Takes the marks and the jump list the runtime kept from the windows before this one, once it
  // answered `state`, the cache of the machine the window runs on: a mark the explorer already
  // has stays as it is, and the jump list is taken when the explorer has none. A place of a
  // machine the window does not keep is kept, with the label of its machine.
  void recall(View& view, State& state, const Context& context);

  // Gives the explorer the keys of the configuration: the default ones with `changes`. The keys
  // typed toward a command are forgotten when the map changed, which it then says.
  bool configure(View& view, const ExplorerKeys& changes);

  // Whether the marks or the jump list changed since the runtime was last given them.
  [[nodiscard]] bool unkept(const View& view) noexcept;

  // The marks and the jump list as the runtime keeps them, in `places`: the marks, then the
  // newest steps of the jump list that fit what a runtime keeps, from the oldest of them. They
  // view the texts of `view` and of `context`. Returns the step the explorer is at, among those.
  [[nodiscard]] std::uint16_t keeping(tbc::mut_a<ds::Vec<KeptPlace, Memory>> places, tbc::ref_a<View> view, tbc::ref_a<Context> context);

  // Says `text` on the line under the windows.
  void say(View& view, std::string_view text, Tone tone = Tone::info);

  // The filter of a window as the runtime searches for it: without the spaces around it, cut to
  // what a search takes.
  [[nodiscard]] tbc::val_a<std::string_view> queryOf(tbc::ref_a<Window> window) noexcept;

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

  // Where the rows dragged are let go: over a row of a window, or over the window itself with a
  // row past its last, and whether they are copied there, not moved.
  struct Drop {
    std::size_t window = 0;
    std::size_t row = 0;
    bool copy = false;
    // Between two machines the rows are copied unless this asks for a move.
    bool move = false;
  };

  // What letting go there would do: how many rows the directory takes, none when it refuses them
  // all, and the row of that directory when the window shows one; none for its root.
  struct Aim {
    std::size_t count = 0;
    ds::Option<std::size_t> row;
    // Whether they would be copied there, not moved.
    bool copy = false;
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

  // Whether a visual selection stands: in visual mode, and while a menu shows over it.
  [[nodiscard]] bool selecting(const View& view) noexcept;
  [[nodiscard]] Range range(const View& view, const Window& window) noexcept;
  [[nodiscard]] bool chosen(const View& view, const Window& window, std::size_t row) noexcept;

  // The absolute path of a row that names one; empty for a title, a note or a line of a diff.
  void pathOf(ds::String<Memory>& path, const Window& window, const State& state, const Context& context, const Row& row);

  // The row's name as it lists: the entry's, the one a change gives it, or the row's own text.
  [[nodiscard]] tbc::val_a<std::string_view> nameOf(tbc::ref_a<Window> window, tbc::ref_a<State> state, const Row& row) noexcept;

}
