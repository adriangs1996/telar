export module telar.runtime.files.directory;

import std;

import telar.runtime.transport.connection;
import telar.wire.files;
import telar.base.memory.allocators;
import telar.base.ds;

export namespace telar::runtime {

  // The order a listing has: directories first, then each group by name without regard to case,
  // and by its bytes where two names differ only in case.
  [[nodiscard]] bool listsBefore(std::string_view left, bool left_directory, std::string_view right, bool right_directory) noexcept;

  // Reads one directory, never what is below it, and measures what its directories hold. It runs
  // on a worker's thread: a directory of any size is read whole there, and only the page asked
  // for crosses to the client.
  class DirectoryReader {
  public:
    // The entries of a directory it keeps to order them; one with more lists these.
    static constexpr std::size_t kept_entries = std::size_t{32} * 1024;
    // How long one request measures before it answers with what it has.
    static constexpr auto measure_time = std::chrono::seconds{2};
    // The levels below a directory it follows while measuring it.
    static constexpr std::size_t measured_depth = 64;
    // The directories whose size it remembers, and for how long: what is below a directory
    // changes without the directory changing, so a size stands for a short while and no more.
    static constexpr std::size_t remembered_sizes = std::size_t{16} * 1024;
    static constexpr auto remembered_time = std::chrono::seconds{30};

    explicit DirectoryReader(ConcurrentMemory& memory);

    // Sends the DirectoryContents of `request`. Throws RequestError for a path that is not an
    // absolute directory this account may read.
    void list(const ListDirectory& request, EncodedReply<ConcurrentMemory>& reply);

    // Sends the DirectorySizes of the directories in the page `request` names, measured until
    // `measure_time` passed: the ones it did not finish say so. With `cancelled` set, before it
    // begins or on its way, it throws RequestError: its sizes gave way to another request.
    void measure(const MeasureDirectory& request, const std::atomic<bool>& cancelled, EncodedReply<ConcurrentMemory>& reply);

    // Forgets the sizes it remembers: the files changed under them.
    void forget() noexcept;

  private:
    using Clock = std::chrono::steady_clock;

    // One entry kept: where its name is in `names_`.
    struct Item {
      std::uint32_t name = 0;
      std::uint16_t name_size = 0;
      FileKind kind = FileKind::other;
      bool directory = false;
      std::uint64_t size = 0;
      FileIdentity identity{};
    };

    // What measuring a directory needs at every level below it.
    struct Measure {
      Clock::time_point deadline;
      const std::atomic<bool>& cancelled;
      std::uint64_t bytes = 0;
      bool complete = true;
      // How many times something below made a size unfit to remember: a directory not walked
      // whole, or a file with several names, which counts once wherever it is met first.
      std::uint32_t flaws = 0;
    };

    // What says a directory is the one it was: where it is, and the time of its last change.
    struct Seen {
      std::uint64_t device = 0;
      std::uint64_t inode = 0;
      std::uint64_t modified_seconds = 0;
      std::uint32_t modified_nanoseconds = 0;

      bool operator==(const Seen&) const noexcept = default;
    };

    // What a directory held when it was measured.
    struct Sized {
      Seen seen;
      std::uint64_t bytes = 0;
      Clock::time_point measured;
    };

    // Reads `path` into `items_`, in a listing's order. `continued` says the request goes on with
    // a directory already asked for, its next page or its sizes: the listing held of it is kept
    // while the directory is the same and no entry came or went, by its inode and the time of its
    // last change, so a long directory is read and sorted once and not once a page.
    void read(std::string_view path, bool continued);
    [[nodiscard]] std::string_view nameOf(const Item& item) const;
    // Adds to `measure` what the directory `name` of `parent` holds on disk, `depth` levels down.
    void add(int parent, const char* name, std::size_t depth, Measure& measure);
    // The same, of a directory seen as `seen`: from what is remembered of it while it is the
    // same directory and was measured lately; else it is walked, and remembered when the walk
    // was whole.
    void addSized(int parent, const char* name, const Seen& seen, std::size_t depth, Measure& measure);

    ds::String<ConcurrentMemory> path_;
    // What the directory was when `items_` was read from it; none while no listing is held whole.
    ds::Option<FileIdentity> read_;
    ds::Vec<char, ConcurrentMemory> names_;
    ds::Vec<Item, ConcurrentMemory> items_;
    // Every entry the directory holds, the ones past `kept_entries` included.
    std::uint32_t total_ = 0;
    // The files with more than one name already counted in the directory being measured.
    ds::Map<std::uint64_t, std::monostate, ConcurrentMemory> counted_;
    // The sizes remembered, by inode.
    ds::Map<std::uint64_t, Sized, ConcurrentMemory> sizes_;
  };

}
