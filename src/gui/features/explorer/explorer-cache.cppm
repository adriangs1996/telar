// The files of one machine as the window holds them, and what it asks the machine's runtime next.
export module telar.gui.features.explorer:cache;

import std;

import :files;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.ds;
import telar.tbc;
import telar.wire.editor;
import telar.wire.files;
import telar.wire.runtime;

export namespace telar::gui::features::explorer {

  // What a machine's runtime answered about its files. A field of the session of that machine:
  // an explorer window on another machine reads that machine's.
  // A place the explorer of a window before this one was, as the runtime of the machine the
  // window runs on kept it: a mark, with its letter, or a step of the jump list, with none.
  // `machine` is the label of its machine, empty for the one the window runs on.
  struct Remembered {
    explicit Remembered(Memory& memory);

    char letter = 0;
    ds::String<Memory> machine;
    ds::String<Memory> root;
    ds::String<Memory> selected;
  };

  // Whether the runtime was asked for the places it keeps, and what became of its answer.
  enum class Recall : std::uint8_t {
    unasked,
    asked,
    answered,
    taken,
  };

  struct State {
    explicit State(Memory& made_in);

    Memory& memory;
    ds::Vec<ds::Box<Directory, Memory>, Memory> directories;
    Repository repository;
    // The paths inspected: the selected one's preview, and each file whose diff a row unfolds.
    ds::Vec<ds::Box<Inspection, Memory>, Memory> inspections;
    // What a filter found below a window's root, and whether this machine's runtime searches
    // paths at all: the session says so when the explorer opens.
    Search search;
    // Who touched the files of the machine, asked once a window shows them.
    Touches touches;
    bool finds = false;
    // The home of the machine's account, which `~` stands for there: empty until its runtime
    // says it, which it is asked once. `located` once it answered, or refused to.
    ds::String<Memory> home;
    bool located = false;
    std::uint64_t locating = 0;
    // The places the runtime keeps of the explorers before this one: asked once the explorer
    // opens on the machine the window runs on, and held here until the view takes them.
    ds::Vec<Remembered, Memory> remembered;
    std::uint16_t remembered_jump = 0;
    Recall recall = Recall::unasked;
    std::uint64_t recalling = 0;
    // The plan in flight, 0 when none; what the last one did, and whether it can be taken back.
    std::uint64_t applying = 0;
    ds::Vec<Outcome, Memory> outcomes;
    bool undoable = false;
    // Whether the outcomes are of changes taken back.
    bool undone = false;
    // The commit in flight, and the last one git made.
    std::uint64_t committing = 0;
    ds::String<Memory> committed;
    // Grows with every answer the rows are built from, and with every plan or commit that ended.
    std::uint64_t revision = 0;
    // Grows with every preview kept: one changes what shows beside the rows, and no row but the
    // ones a diff is unfolded below.
    std::uint64_t previews = 0;
    std::uint64_t settled = 0;
    // The requests on files in flight.
    std::uint8_t in_flight = 0;
    // What the runtime last refused.
    runtime::FixedText<ExplorerLimits::error_bytes> error;
    // Counts the reads, for the directory read longest ago.
    std::uint64_t clock = 0;
    // The requests of transfers in flight on this machine, and their answers not yet taken.
    ds::Vec<std::uint64_t, Memory> carrying;
    ds::Vec<Carried, Memory> carried;
    // Grows with each connection: a request that left on an earlier one is answered by none.
    std::uint64_t epoch = 0;
  };

  // The directory `path` as the window holds it; none when it never asked for it.
  [[nodiscard]] tbc::val_a<const Directory*> find(tbc::ref_a<State> state, std::string_view path) noexcept;

  // What the runtime said of `path`; none before it answered.
  [[nodiscard]] tbc::val_a<const Inspection*> inspected(tbc::ref_a<State> state, std::string_view path) noexcept;

  // What the window needs of a machine that it does not hold: a page of a directory, the sizes
  // of one, the repository's changes, or a preview.
  enum class NeedKind : std::uint8_t {
    listing,
    sizes,
    changes,
    inspection,
    // The paths below `path` that match `text`.
    search,
    // Where the home of the machine's account is.
    home,
    // Who touched the files of the machine lately.
    touches,
  };

  struct Need {
    NeedKind kind = NeedKind::listing;
    std::string_view path;
    std::string_view text;
  };

  // Whether the window may ask the machine's runtime for more now.
  [[nodiscard]] bool mayAsk(const State& state) noexcept;

  // Whether the window still lacks `need`, and no request for it is in flight.
  [[nodiscard]] bool lacks(const State& state, const Need& need) noexcept;

  // The requests for a need. Whoever sends one gives it its id, and says so with `asked`.
  [[nodiscard]] tbc::val_a<ListDirectory> listing(const State& state, tbc::val_a<std::string_view> path) noexcept;
  [[nodiscard]] tbc::val_a<MeasureDirectory> measure(const State& state, tbc::val_a<std::string_view> path) noexcept;
  [[nodiscard]] tbc::val_a<FindPaths> search(const State& state, tbc::val_a<Need> need) noexcept;

  // The request for `need` left under `request_id`.
  void asked(State& state, const Need& need, std::uint64_t request_id);

  // The plan left under `request_id`, or the request that takes the last one back when `undo`;
  // and the commit.
  void applying(State& state, std::uint64_t request_id, bool undo) noexcept;
  void committing(State& state, std::uint64_t request_id) noexcept;

  // Keeps an answer; false for one the window does not wait for.
  bool receive(State& state, const DirectoryContents& listing);
  bool receive(State& state, const DirectorySizes& sizes);
  bool receive(State& state, const RepositoryChanges& changes);
  bool receive(State& state, const FileInspection& inspection);
  bool receive(State& state, const FilesChanged& changed);
  bool receive(State& state, const ChangesCommitted& committed);
  bool receive(State& state, const HomeLocated& located);
  bool receive(State& state, const FileTouches& answer);

  // The runtime was asked for the places it keeps, under `request_id`.
  void recalling(State& state, std::uint64_t request_id) noexcept;
  bool receive(State& state, const PlacesKept& kept);

  // A request of a transfer left under `request_id`: its answer is kept for the transfer.
  void carrying(State& state, std::uint64_t request_id);
  bool receive(State& state, const FileChunk& chunk);
  bool receive(State& state, const FileWritten& written);
  bool receive(State& state, const FileWriteEnded& ended);
  // The answer to a transfer's request, taken out of the cache; none before it arrived.
  [[nodiscard]] ds::Option<Carried> carried(State& state, std::uint64_t request_id);
  // The matches of the search asked last; false for an answer to one that a later query replaced.
  bool receive(State& state, const PathResults& results);

  // The runtime refused a request; false when it is none of the explorer's.
  bool fail(State& state, const RequestFailed& failure);

  // What `path` holds changed on disk: the directory is read again, and the repository asked
  // again. An empty path says all of it did.
  void invalidate(State& state, std::string_view path) noexcept;

  // The directory `path` is read again the next time its listing is asked for, and nothing
  // else of the machine is: a tree that is carried walks what its directories hold now.
  void relist(State& state, std::string_view path) noexcept;

  // A pane of the machine did something: who touched what is asked again, if it was asked before.
  void stir(State& state) noexcept;

  // Forgets what was asked: a new connection answers none of it.
  void reset(State& state) noexcept;

}
