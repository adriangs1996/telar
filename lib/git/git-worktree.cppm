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

    [[nodiscard]] unsigned stage() const noexcept;
    [[nodiscard]] bool assumeValid() const noexcept;
    [[nodiscard]] bool skipWorktree() const noexcept;
    [[nodiscard]] bool intentToAdd() const noexcept;
  };

  // One cache-tree node of the TREE extension; `end` is the index past its subtree. Its name is kept
  // as where it lies in the index's bytes, which Index::treeName reads: the index owns both.
  struct CacheTreeNode {
    std::uint32_t name_offset = 0;
    std::uint32_t name_size = 0;
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

    [[nodiscard]] std::string_view path(const IndexEntry& entry) const noexcept;
    [[nodiscard]] std::string_view treeName(const CacheTreeNode& node) const noexcept;

    // The index's own modification time: entries modified at or after it are racy.
    [[nodiscard]] std::int64_t timestamp() const noexcept;

    ds::Vec<IndexEntry, Memory> entries;
    ds::Vec<CacheTreeNode, Memory> tree;
    Fingerprint fingerprint;
    IndexState state = IndexState::ready;

  private:
    IndexState parse(const Limits& limits);
    // Static, so parsing the index's bytes borrows them apart from the tree it fills.
    static bool parseTree(ds::Vec<CacheTreeNode, Memory>& tree, std::size_t entries_held, ObjectFormat format, std::span<const std::uint8_t> data, std::size_t& position, std::size_t depth, const Limits& limits);

    ds::String<Memory> bytes_;
    ds::String<Memory> paths_;
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
    ds::String<Memory>& buffer(std::size_t depth) noexcept;

    // What one comparison reads and counts, handed to each step rather than kept between them.
    struct Sources {
      ObjectDatabase& objects;
      const Index& index;
      const Limits& limits;
      ChangeCounts& counts;
    };

    bool readTree(Sources& sources, const ObjectId& id, std::size_t depth);
    static std::string_view relative(const Index& index, std::uint32_t entry, std::size_t prefix) noexcept;

    // The index entries [begin, end) are new to HEAD.
    void addRange(Sources& sources, std::uint32_t begin, std::uint32_t end) noexcept;

    // Every file below tree `id` left the index.
    bool deleteTree(Sources& sources, const ObjectId& id, std::size_t depth);

    bool compareTree(Sources& sources, const ObjectId& id, std::size_t prefix, std::uint32_t begin, std::uint32_t end, std::uint32_t cache, std::size_t depth);

    // Past the stages of the entry at `begin`.
    static std::uint32_t pathEnd(const Index& index, std::uint32_t begin, std::uint32_t end) noexcept;

    // Past the entries below directory `component` of the current prefix.
    static std::uint32_t groupEnd(const Index& index, std::uint32_t begin, std::uint32_t end, std::size_t prefix, std::string_view component) noexcept;

    ds::Vec<ds::String<Memory>, Memory> trees_;
    Memory& memory_;
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
      ds::Array<FileDescriptor, 128> descriptors_;
      ds::Array<std::size_t, 128> ends_{};
      ds::Array<char, 4096> path_;
    };

    // git's ce_match_stat, then the content when stat data cannot decide.
    Verdict examine(const IndexEntry& entry, std::int64_t index_time, int parent, const char* name, const struct stat& status, Verified& verified);

    ds::Option<ObjectId> hashLink(int parent, const char* name, const struct stat& status);
    ds::Option<ObjectId> hashFile(int parent, const char* name, const struct stat& expected);

    Options options_;
    // The bytes one scan may hash, from its limits.
    std::uint64_t hashed_limit_ = 0;
    std::uint64_t hashed_bytes_ = 0;
    Fingerprint verified_index_;
    ds::Vec<Verified, Memory> verified_;
    ds::String<Memory> buffer_;
    Directories directories_;
  };

}
