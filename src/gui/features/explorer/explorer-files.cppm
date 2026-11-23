// What a machine's runtime answered about its files, as the window keeps it: the directories it
// listed, what git holds of the repository under the explorer's root, and the path a preview shows.
export module telar.gui.features.explorer:files;

import std;

import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.ds;
import telar.wire.files;

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

  // What became of one operation of the plan last applied.
  struct Outcome {
    FileOutcome outcome = FileOutcome::done;
    ds::String<Memory> path;
  };

}
