export module telar.git:worktree;

import std;
import telar.base.memory.allocators;
import telar.platform.primitives;
import :format;
import :objects;
import telar.sys.posix;
import telar.base.ds;

// The index (versions 2 to 4) and the two comparisons git status makes with
// it: HEAD's tree against the index (staged) and the index against the
// working tree (unstaged). Paths come from the index, so they are untrusted:
// the working tree is walked with openat and O_NOFOLLOW, one directory
// descriptor per component, and never through a symlink.

export namespace telar::git {

  // Paths counted per kind, as `git status --porcelain=v2` reports them with
  // renames off, untracked files hidden and submodule work trees not inspected.
  struct ChangeCounts {
    std::uint32_t staged_added = 0;
    std::uint32_t staged_modified = 0; // content, mode or type
    std::uint32_t staged_deleted = 0;
    std::uint32_t unstaged_modified = 0; // content, mode or type
    std::uint32_t unstaged_deleted = 0;
    std::uint32_t intent_to_add = 0; // `git add -N` entries
    std::uint32_t conflicted = 0;
  };

}

namespace telar::git {

  struct IndexEntry {
    std::uint32_t changed_seconds;
    std::uint32_t changed_nanoseconds;
    std::uint32_t modified_seconds;
    std::uint32_t modified_nanoseconds;
    std::uint32_t device;
    std::uint32_t inode;
    std::uint32_t mode;
    std::uint32_t user;
    std::uint32_t group;
    std::uint32_t size;
    ObjectId id;
    std::uint32_t path_offset;
    std::uint16_t path_length;
    std::uint16_t flags;
    std::uint16_t extended;

    unsigned stage() const noexcept;
    bool assumeValid() const noexcept;
    bool skipWorktree() const noexcept;
    bool intentToAdd() const noexcept;
  };

  // One cache-tree node of the TREE extension; `end` is the index past its subtree.
  struct CacheTreeNode {
    std::string_view name;
    std::int32_t entries = -1;
    std::uint32_t end = 0;
    ObjectId id;
  };

  enum class IndexState : std::uint8_t {
    ready,
    unsupported,
    invalid,
  };

  class Index {
  public:
    explicit Index(Memory& memory) noexcept;

    // Parses <gitdir>/index again when its fingerprint changed. A missing
    // index is an empty one, as in a repository nobody added files to yet.
    IndexState load(int gitdir, ObjectFormat format, const Limits& limits);

    std::string_view path(const IndexEntry& entry) const noexcept;

    // The index's own modification time: entries modified at or after it are racy.
    std::int64_t timestamp() const noexcept;

    Vector<IndexEntry, Memory> entries;
    Vector<CacheTreeNode, Memory> tree;
    Fingerprint fingerprint;
    IndexState state = IndexState::ready;

  private:
    IndexState parse(const Limits& limits);
    bool parseTree(std::span<const std::uint8_t> data, std::size_t& position, std::size_t depth, const Limits& limits);

    String<Memory> bytes_;
    String<Memory> paths_;
    ObjectFormat format_ = ObjectFormat::sha1;
    bool loaded_ = false;
  };

  inline constexpr std::uint32_t no_cache_tree = std::numeric_limits<std::uint32_t>::max();

  // Compares HEAD's tree with the index, recursing only into trees whose
  // cache-tree entry is missing, invalid or different.
  class StagedComparison {
  public:
    explicit StagedComparison(Memory& memory) noexcept;

    // `tree` is HEAD's root tree, or nullopt on an unborn branch.
    bool compare(ObjectDatabase& objects, const Index& index, ds::Option<ObjectId> tree, const Limits& limits, ChangeCounts& counts);

    std::uint64_t trees_read = 0;

  private:
    // One tree buffer per depth, allocated before the walk: a reader at one
    // depth keeps viewing its buffer while deeper trees are read.
    String<Memory>& buffer(std::size_t depth) noexcept;

    bool readTree(const ObjectId& id, std::size_t depth);
    std::string_view relative(std::uint32_t entry, std::size_t prefix) const noexcept;

    // The index entries [begin, end) are new to HEAD.
    void addRange(std::uint32_t begin, std::uint32_t end) noexcept;

    // Every file below tree `id` left the index.
    bool deleteTree(const ObjectId& id, std::size_t depth);

    bool compareTree(const ObjectId& id, std::size_t prefix, std::uint32_t begin, std::uint32_t end, std::uint32_t cache, std::size_t depth);

    // Past the stages of the entry at `begin`.
    std::uint32_t pathEnd(std::uint32_t begin, std::uint32_t end) const noexcept;

    // Past the entries below directory `component` of the current prefix.
    std::uint32_t groupEnd(std::uint32_t begin, std::uint32_t end, std::size_t prefix, std::string_view component) const noexcept;

    Vector<String<Memory>, Memory> trees_;
    Memory& memory_;
    ObjectDatabase* objects_ = nullptr;
    const Index* index_ = nullptr;
    const Limits* limits_ = nullptr;
    ChangeCounts* counts_ = nullptr;
    std::size_t trees_read_ = 0;
  };

  // The verdict of a racily clean entry whose content was hashed, kept while
  // neither the index nor the file changes.
  struct Verified {
    Fingerprint file;
    bool modified = false;
    bool valid = false;
  };

  // Compares each index entry with the working tree.
  class UnstagedComparison {
  public:
    explicit UnstagedComparison(Memory& memory) noexcept;

    struct Options {
      ObjectFormat format = ObjectFormat::sha1;
      bool file_mode = true;
      bool symlinks = true;
    };

    bool compare(int worktree, const Index& index, Options options, const Limits& limits, ChangeCounts& counts);

    std::uint64_t entries_checked = 0;
    std::uint64_t files_hashed = 0;
    std::uint64_t bytes_hashed = 0;

  private:
    bool scan(int worktree, const Index& index, Options options, const Limits& limits, ChangeCounts& counts);

    enum class Verdict : std::uint8_t {
      clean,
      modified,
      deleted,
      unknown,
    };

    // Directory descriptors of the current entry's parent path, reused while
    // consecutive index entries share a prefix.
    class Directories {
    public:
      void reset(int root) noexcept;

      // The descriptor of `directory`, `missing` if a component is absent, a
      // symlink or not a directory, or -1 on any other failure.
      int open(std::string_view directory, std::size_t maximum_depth, bool& missing) noexcept;

    private:
      static constexpr std::size_t no_missing = std::numeric_limits<std::size_t>::max();
      int root_ = -1;
      std::size_t depth_ = 0;
      std::size_t missing_ = no_missing;
      std::array<FileDescriptor, 128> descriptors_;
      std::array<std::size_t, 128> ends_{};
      std::array<char, 4096> path_;
    };

    // git's ce_match_stat, then the content when stat data cannot decide.
    Verdict examine(const IndexEntry& entry, std::int64_t index_time, int parent, const char* name, const struct stat& status, Verified& verified);

    ds::Option<ObjectId> hashLink(int parent, const char* name, const struct stat& status);
    ds::Option<ObjectId> hashFile(int parent, const char* name, const struct stat& expected);

    Options options_;
    const Limits* limits_ = nullptr;
    std::uint64_t hashed_bytes_ = 0;
    Fingerprint verified_index_;
    Vector<Verified, Memory> verified_;
    String<Memory> buffer_;
    Directories directories_;
  };

}
