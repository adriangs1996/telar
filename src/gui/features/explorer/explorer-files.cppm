// What a machine's runtime answered about its files, as the window keeps it: the directories it
// listed, what git holds of the repository under the explorer's root, and the path a preview shows.
export module telar.gui.features.explorer:files;

import std;

import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.ds;
import telar.wire.files;
import telar.wire.vocabulary;

export namespace telar::gui::features::explorer {

  struct ExplorerLimits {
    // The directories the window keeps of one machine; the one read longest ago goes first.
    static constexpr std::size_t directories = 256;
    // The entries of one directory the window keeps: the pages it asked for.
    static constexpr std::size_t entries = std::size_t{16} * 1024;
    // The requests on files the window keeps in flight with one runtime.
    static constexpr std::size_t in_flight = 4;
    // The previews the window keeps of one machine.
    static constexpr std::size_t inspections = 16;
    static constexpr std::size_t error_bytes = 256;
  };

  // An entry of a directory, as the runtime listed it.
  struct Entry {
    // Where its name is among the directory's names.
    std::uint32_t name = 0;
    std::uint16_t name_size = 0;
    FileKind kind = FileKind::file;
    bool directory = false;
    // A file's bytes; a directory's once the runtime measured it.
    std::uint64_t size = 0;
    // Whether a directory was measured, and whether the runtime finished measuring it.
    bool measured = false;
    bool complete = false;
    FileIdentity identity{};
  };

  // One directory of the machine: the pages of it the runtime sent, in the runtime's order.
  struct Directory {
    explicit Directory(Memory& memory);

    ds::String<Memory> path;
    ds::Vec<char, Memory> names;
    ds::Vec<Entry, Memory> entries;
    // Every entry the directory holds, the ones not asked for included.
    std::uint32_t total = 0;
    // A page arrived; and the runtime refused the directory.
    bool listed = false;
    bool failed = false;
    // What it holds changed on disk since: the next read replaces what is kept.
    bool stale = false;
    // The listing and the measure in flight, 0 when none.
    std::uint64_t listing = 0;
    std::uint64_t measuring = 0;
    // The entries a measure covered already.
    std::uint32_t measured = 0;
    // When it was last read, for the one read longest ago to go first.
    std::uint64_t used = 0;

    [[nodiscard]] std::string_view name(const Entry& entry) const noexcept;
    // Whether every entry it holds was asked for.
    [[nodiscard]] bool whole() const noexcept;
  };

  // A path git says something of, from the repository's top.
  struct Change {
    std::uint32_t path = 0;
    std::uint16_t path_size = 0;
    FileState staged = FileState::unchanged;
    FileState unstaged = FileState::unchanged;
    std::uint32_t added = 0;
    std::uint32_t removed = 0;
  };

  // What git holds of the repository the explorer's root is in. Its changes are kept by path, so
  // a row finds its own, and a directory the ones below it, by a search.
  struct Repository {
    explicit Repository(Memory& memory);

    // The directory asked about, and the repository's top: empty outside one.
    ds::String<Memory> asked;
    ds::String<Memory> root;
    ds::String<Memory> branch;
    bool upstream = false;
    std::uint32_t ahead = 0;
    std::uint32_t behind = 0;
    bool truncated = false;
    ds::Vec<char, Memory> text;
    ds::Vec<Change, Memory> changes;
    // How many paths the index holds changes of, the working tree does, and git does not track.
    std::uint32_t staged = 0;
    std::uint32_t unstaged = 0;
    std::uint32_t untracked = 0;
    bool known = false;
    bool stale = false;
    std::uint64_t waiting = 0;

    [[nodiscard]] std::string_view path(const Change& change) const noexcept;
  };

  // What git says of one absolute path: the change of a file, or for a directory how many paths
  // below it changed.
  struct Standing {
    FileState staged = FileState::unchanged;
    FileState unstaged = FileState::unchanged;
    std::uint32_t added = 0;
    std::uint32_t removed = 0;
    // The changed paths below a directory.
    std::uint32_t below = 0;
    bool ignored = false;
  };

  // What git says of `path`, a directory when `directory`.
  [[nodiscard]] Standing standing(const Repository& repository, std::string_view path, bool directory) noexcept;

  // The path a preview shows, as the runtime inspected it.
  struct Inspection {
    explicit Inspection(Memory& memory);

    ds::String<Memory> asked;
    ds::String<Memory> path;
    FileKind kind = FileKind::file;
    std::uint64_t size = 0;
    FileIdentity identity{};
    ds::String<Memory> target;
    bool binary = false;
    bool truncated = false;
    ds::String<Memory> text;
    runtime::FixedText<FileLimits::commit_bytes> commit;
    std::uint64_t committed_seconds = 0;
    ds::String<Memory> subject;
    ds::String<Memory> diff;
    bool known = false;
    std::uint64_t waiting = 0;
    std::uint64_t used = 0;
  };

  // A path the runtime found below a root for a query: where it is in the search's text, from
  // that root.
  struct Match {
    std::uint32_t path = 0;
    std::uint16_t path_size = 0;
    bool directory = false;
    // What the search says git holds of it: nothing when it is as committed.
    FileState state = FileState::unchanged;
  };

  // What the runtime's path index found below `root` for `query`: the best matches of its last
  // answer, in its order. An answer replaces the one before it while the index is still read.
  struct Search {
    explicit Search(Memory& memory);

    ds::String<Memory> root;
    ds::String<Memory> query;
    ds::Vec<char, Memory> text;
    ds::Vec<Match, Memory> matches;
    // The request the answers come under; 0 once the index was read whole, or it failed.
    std::uint64_t waiting = 0;
    // Whether an answer for this root and query is held.
    bool known = false;
    // More paths match than an answer carries.
    bool truncated = false;
    // The files changed since it was answered: it is asked again, of an index read again.
    bool stale = false;

    [[nodiscard]] std::string_view path(const Match& match) const noexcept;
    // Whether this is the search of `query` below `root`, answered or still asked.
    [[nodiscard]] bool of(std::string_view directory, std::string_view text_asked) const noexcept;
  };

  // A file a pane touched, as the runtime told it: where its path is in the touches' text, who
  // did it, with which command or tool, and when.
  struct Touch {
    std::uint32_t path = 0;
    std::uint16_t path_size = 0;
    TouchActor actor = TouchActor::user;
    AgentProvider provider = AgentProvider::unknown;
    std::uint64_t pane = 0;
    runtime::FixedText<FileLimits::verb_bytes> verb;
    std::uint64_t seconds = 0;
  };

  // Who touched the files of a machine lately, the newest first: what its runtime last answered.
  struct Touches {
    explicit Touches(Memory& memory);

    ds::Vec<char, Memory> text;
    ds::Vec<Touch, Memory> items;
    // The request its answer comes under.
    std::uint64_t waiting = 0;
    bool known = false;
    bool truncated = false;
    // A pane did something since the answer: it is asked again.
    bool stale = false;
    // Grows with every answer that says something else than the one before it.
    std::uint64_t revision = 0;

    [[nodiscard]] std::string_view path(const Touch& touch) const noexcept;
  };

  // What became of one operation of the plan last applied.
  struct Outcome {
    FileOutcome outcome = FileOutcome::done;
    ds::String<Memory> path;
  };

  // What a runtime answered a request of a transfer: a chunk read, a chunk written, the file
  // ended, its source sent to the trash, or a refusal.
  enum class CarriedKind : std::uint8_t {
    chunk,
    written,
    ended,
    trashed,
    failed,
  };

  // An answer to a transfer's request, kept by the machine's cache until the transfer takes it.
  struct Carried {
    explicit Carried(Memory& memory);

    std::uint64_t request = 0;
    CarriedKind kind = CarriedKind::failed;
    // Of a chunk read: where it starts, how long its file is, and whether it is the last. Of
    // one written: how long the partial is now.
    std::uint64_t offset = 0;
    std::uint64_t size = 0;
    bool end = false;
    ds::Vec<Byte, Memory> bytes;
    // The partial a chunk was written to, the path a file ended at, or what the runtime said
    // when it refused.
    ds::String<Memory> text;
    FileOutcome outcome = FileOutcome::done;
  };

}
