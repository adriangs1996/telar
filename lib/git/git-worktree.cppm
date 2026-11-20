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
    std::uint32_t changed_seconds = 0;
    std::uint32_t changed_nanoseconds = 0;
    std::uint32_t modified_seconds = 0;
    std::uint32_t modified_nanoseconds = 0;
    std::uint32_t device = 0;
    std::uint32_t inode = 0;
    std::uint32_t mode = 0;
    std::uint32_t user = 0;
    std::uint32_t group = 0;
    std::uint32_t size = 0;
    ObjectId id;
    std::uint32_t path_offset = 0;
    std::uint16_t path_length = 0;
    std::uint16_t flags = 0;
    std::uint16_t extended = 0;

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

    [[nodiscard]] std::span<const IndexEntry> entries() const noexcept;
    [[nodiscard]] std::span<const CacheTreeNode> tree() const noexcept;
    [[nodiscard]] const Fingerprint& fingerprint() const noexcept;

  private:
    // A cache-tree node whose subtrees are still being read, and how many are left.
    struct OpenTree {
      std::uint32_t node = 0;
      std::uint32_t remaining = 0;
    };

    // The TREE extension's bytes: its nodes start at `position` of `data`, and the index holds
    // `entries_held` entries.
    struct TreeExtension {
      std::span<const std::uint8_t> data;
      std::size_t position = 0;
      std::size_t entries_held = 0;
      ObjectFormat format = ObjectFormat::sha1;
    };

    IndexState parse(const Limits& limits);

    // The extensions from `position` to the end of `data`, the index's bytes before their checksum.
    IndexState parseExtensions(std::span<const std::uint8_t> data, std::size_t position, const Limits& limits);

    // Static, so parsing the index's bytes borrows them apart from the tree it fills. Returns the
    // position past the tree, or none when it is malformed.
    static ds::Option<std::size_t> parseTree(TreeExtension extension, const Limits& limits, ds::Vec<CacheTreeNode, Memory>& tree, ds::Vec<OpenTree, Memory>& open);

    ds::Vec<IndexEntry, Memory> entries_;
    ds::Vec<CacheTreeNode, Memory> tree_;
    ds::Vec<OpenTree, Memory> open_trees_;
    Fingerprint fingerprint_;
    IndexState state_ = IndexState::ready;
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

    // The trees read since the last resetTreesRead().
    [[nodiscard]] std::uint64_t treesRead() const noexcept;
    void resetTreesRead() noexcept;

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

    // The index entries [begin, end) below the directory that ends `prefix` bytes into their paths,
    // its cache-tree node, and the depth of its tree.
    struct Subtree {
      std::size_t prefix = 0;
      std::uint32_t begin = 0;
      std::uint32_t end = 0;
      std::uint32_t cache = no_cache_tree;
      std::size_t depth = 0;
    };

    // An index entry and how it sorts against a tree entry.
    struct Aligned {
      std::uint32_t entry = 0;
      int order = 1;
    };

    bool readTree(Sources& sources, const ObjectId& id, std::size_t depth);
    static std::string_view relative(const Index& index, std::uint32_t entry, std::size_t prefix) noexcept;

    // The index entries [begin, end) are new to HEAD.
    static void addRange(Sources& sources, std::uint32_t begin, std::uint32_t end) noexcept;

    // Every file below tree `id` left the index.
    bool deleteTree(Sources& sources, const ObjectId& id, std::size_t depth);

    bool compareTree(Sources& sources, const ObjectId& id, Subtree subtree);

    // Adds the index entries from `current` that sort before the tree entry `name` as new; returns
    // the first that does not, and how it sorts against the entry.
    static Aligned addBefore(Sources& sources, const Subtree& subtree, std::uint32_t current, std::string_view name, bool directory) noexcept;

    // The index entries at `current` with the path of the tree's file `entry`: a single stage-0
    // entry that differs from it is staged as modified. Returns the index past them.
    static std::uint32_t compareFile(Sources& sources, const Subtree& subtree, std::uint32_t current, const TreeEntry& entry) noexcept;

    // Past the stages of the entry at `begin`.
    static std::uint32_t pathEnd(const Index& index, std::uint32_t begin, std::uint32_t end) noexcept;

    // Past the entries below directory `component` of the current prefix.
    static std::uint32_t groupEnd(const Index& index, std::uint32_t begin, std::uint32_t end, std::size_t prefix, std::string_view component) noexcept;

    ds::Vec<ds::String<Memory>, Memory> trees_;
    Memory& memory_;
    std::size_t trees_read_ = 0;
    std::uint64_t trees_counted_ = 0;
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

    // Work the comparisons did since the last resetWork().
    struct Work {
      std::uint64_t entries_checked = 0;
      std::uint64_t files_hashed = 0;
      std::uint64_t bytes_hashed = 0;
    };

    [[nodiscard]] const Work& work() const noexcept;
    void resetWork() noexcept;

  private:
    bool scan(int worktree, const Index& index, Options options, const Limits& limits, ChangeCounts& counts);

    enum class Verdict : std::uint8_t {
      clean,
      modified,
      deleted,
      unknown,
    };

    // A file of the work tree: its name in the directory `parent`, and what lstat found.
    struct FileAt {
      int parent = -1;
      const char* name = nullptr;
      const struct stat& status;
    };

    // The verdict of index entry `current`, whose path the work tree may hold limits.path_depth
    // directories deep.
    Verdict check(const Index& index, std::size_t current, const Limits& limits);

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
      static constexpr std::size_t depth_capacity = 128;
      static constexpr std::size_t path_capacity = 4096;

      // How many open levels `directory` shares with the current path.
      [[nodiscard]] std::size_t sharedLevels(std::string_view directory) const noexcept;

      // Closes the levels past the first `keep`.
      void closeFrom(std::size_t keep) noexcept;

      // Opens the components of `directory` past the open levels; false on a failure other than a
      // missing component.
      bool openFrom(std::string_view directory, std::size_t maximum_depth) noexcept;

      // Opens `component` as the next level, or marks it missing; false on any other failure.
      bool openLevel(std::string_view component) noexcept;

      int root_ = -1;
      std::size_t depth_ = 0;
      std::size_t missing_ = no_missing;
      ds::Array<FileDescriptor, depth_capacity> descriptors_;
      ds::Array<std::size_t, depth_capacity> ends_{};
      ds::Array<char, path_capacity> path_;
    };

    // git's ce_match_stat, then the content when stat data cannot decide.
    Verdict examine(const IndexEntry& entry, std::int64_t index_time, FileAt file, Verified& verified);

    // What the file's type says before its stat data: modified, deleted or unknown, or none when the
    // type matches the entry's.
    [[nodiscard]] ds::Option<Verdict> typeVerdict(const IndexEntry& entry, const struct stat& status) const noexcept;

    ds::Option<ObjectId> hashLink(FileAt file);
    ds::Option<ObjectId> hashFile(FileAt file);

    Options options_;
    // The bytes one scan may hash, from its limits.
    std::uint64_t hashed_limit_ = 0;
    std::uint64_t hashed_bytes_ = 0;
    Fingerprint verified_index_;
    Work work_;
    ds::Vec<Verified, Memory> verified_;
    ds::String<Memory> buffer_;
    Directories directories_;
  };

}
