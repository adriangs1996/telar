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

    explicit DirectoryReader(ConcurrentMemory& memory);

    // Sends the DirectoryContents of `request`. Throws RequestError for a path that is not an
    // absolute directory this account may read.
    void list(const ListDirectory& request, EncodedReply<ConcurrentMemory>& reply);

    // Sends the DirectorySizes of the directories in the page `request` names, measured until
    // `measure_time` passed or `cancelled` is set: the ones it did not finish say so.
    void measure(const MeasureDirectory& request, const std::atomic<bool>& cancelled, EncodedReply<ConcurrentMemory>& reply);

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
    };

    // Reads `path` into `items_`, in a listing's order.
    void read(std::string_view path);
    [[nodiscard]] std::string_view nameOf(const Item& item) const noexcept;
    // Adds to `measure` what the directory `name` of `parent` holds on disk, `depth` levels down.
    void add(int parent, const char* name, std::size_t depth, Measure& measure);

    ds::String<ConcurrentMemory> path_;
    ds::Vec<char, ConcurrentMemory> names_;
    ds::Vec<Item, ConcurrentMemory> items_;
    // Every entry the directory holds, the ones past `kept_entries` included.
    std::uint32_t total_ = 0;
    // The files with more than one name already counted in the directory being measured.
    ds::Map<std::uint64_t, std::monostate, ConcurrentMemory> counted_;
  };

}
