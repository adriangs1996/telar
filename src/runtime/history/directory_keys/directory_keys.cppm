export module telar.runtime.history.directory_keys;

import std;
import telar.tbc;
import telar.sys.posix;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.ds;

// The key a history scope matches a directory by: its real path when it exists, so a link to it
// and the slash it may end with name it the same way, else the path as it was written. Resolving
// a path can block for as long as a network mount hangs, so a helper thread resolves it while the
// history waits a bounded time; past it the history keys the directory as written. Keys are kept
// a short while, as the same few directories come back with every command.
export namespace telar::runtime {

  // A directory as the history shows it: as it was written, without the slashes it ends with.
  [[nodiscard]] std::string_view writtenDirectory(std::string_view path) noexcept;

  // The key of `path` resolved on the calling thread, viewed in `buffer` or in `path`: for the
  // work that already runs once, as a migration.
  [[nodiscard]] tbc::val_a<std::string_view> resolveDirectoryKey(tbc::val_a<std::string_view> path, tbc::mut_a<ds::Array<char, PATH_MAX>> buffer) noexcept;

  // What resolves a path's key on the helper thread: resolveDirectoryKey, or in a test what stands
  // for a mount that hangs.
  using DirectoryResolver = tbc::val_a<std::string_view> (*)(tbc::val_a<std::string_view> path, tbc::mut_a<ds::Array<char, PATH_MAX>> buffer) noexcept;

  class [[tbc::shared]] DirectoryKeys {
  public:
    static constexpr std::size_t maximum_cached = 1024;
    static constexpr auto lifetime = std::chrono::seconds{30};
    static constexpr auto patience = std::chrono::milliseconds{25};

    explicit DirectoryKeys(ConcurrentMemory& memory, DirectoryResolver resolver = resolveDirectoryKey);
    ~DirectoryKeys();

    DirectoryKeys(const DirectoryKeys&) = delete;
    DirectoryKeys& operator=(const DirectoryKeys&) = delete;
    DirectoryKeys(DirectoryKeys&&) = delete;
    DirectoryKeys& operator=(DirectoryKeys&&) = delete;

    // The key of `path`, written to `out`; empty for one longer than any directory's. Any
    // thread may ask.
    void key(std::string_view path, FixedText<PATH_MAX>& out);

    // Forgets every key, as when directories moved.
    void forget() noexcept;

  private:
    using Clock = std::chrono::steady_clock;

    struct Cached {
      ds::String<ConcurrentMemory> key;
      Clock::time_point resolved;
    };

    // What the helper shares with the keys, which outlives them while it waits on a hung mount.
    struct Shared {
      explicit Shared(ConcurrentMemory& memory);

      std::mutex mutex;
      std::condition_variable asked;
      std::condition_variable answered;
      ds::Map<ds::String<ConcurrentMemory>, Cached, ConcurrentMemory> cached;
      // The one path the helper resolves at a time, and what it found.
      FixedText<PATH_MAX> asking;
      FixedText<PATH_MAX> answer;
      std::uint64_t asked_count = 0;
      std::uint64_t answered_count = 0;
      bool busy = false;
      bool stopping = false;
    };

    static void cache(ConcurrentMemory& memory, Shared& shared, std::string_view path, std::string_view key);
    static void resolve(ConcurrentMemory& memory, const std::shared_ptr<Shared>& owner, DirectoryResolver resolver) noexcept;

    ConcurrentMemory& memory_;
    std::shared_ptr<Shared> shared_;
    std::jthread helper_;
  };

}
