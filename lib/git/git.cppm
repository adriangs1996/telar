module;
#include "tbc/hot_path.hpp"
#include <sys/stat.h>

export module telar.git;

import std;
export import telar.base.memory.allocators;
import telar.platform.primitives;
export import :format;
import :config;
import :objects;
import :history;
export import :worktree;

// A native, read-only reader of a repository's state: the branch, its
// upstream and divergence, and the counts git status reports. It never runs
// git or any other program, never runs hooks and never honours config that
// runs code; every byte it reads from the repository is untrusted.

export namespace telar::git {

  enum class RepositoryState : std::uint8_t {
    none, // no repository contains the directory
    ready,
    not_owned,   // owned by another user: git's safe.directory default refuses it
    unsupported, // a repository version, extension or ref storage this reader lacks
    invalid,     // a malformed .git file, git directory or config
    unknown,     // a system error or a resource limit
  };

  enum class HeadState : std::uint8_t {
    unknown,
    branch,   // on `branch`, at `head_id`
    unborn,   // on `branch`, which has no commit yet
    detached, // at `head_id`
  };

  enum class UpstreamState : std::uint8_t {
    none,     // no branch.<name>.merge, or detached
    tracking, // `upstream_name` at `upstream_id`
    gone,     // configured, but its remote-tracking ref does not exist
    unknown,
  };

  enum class Accuracy : std::uint8_t {
    exact,
    unknown,        // unreadable data or a limit reached
    unsupported,    // a format this reader lacks, such as a split index
    not_applicable, // a bare repository, or no upstream
  };

  // Work one read did; cached parts cost nothing.
  struct ReadWork {
    std::uint64_t objects_read = 0;
    std::uint64_t commits_read = 0;
    std::uint64_t trees_read = 0;
    std::uint64_t entries_checked = 0;
    std::uint64_t files_hashed = 0;
    std::uint64_t bytes_hashed = 0;
  };

  template <Allocator Memory>
  struct Status {
    explicit Status(Memory& memory);

    RepositoryState repository = RepositoryState::none;
    ObjectFormat format = ObjectFormat::sha1;
    bool bare = false;
    bool linked_worktree = false;

    HeadState head = HeadState::unknown;
    String<Memory> branch; // short name, such as "main"; empty when detached
    ObjectId head_id;

    UpstreamState upstream = UpstreamState::none;
    String<Memory> upstream_name; // short name, such as "origin/main"
    ObjectId upstream_id;

    Accuracy divergence = Accuracy::not_applicable;
    std::uint32_t ahead = 0;
    std::uint32_t behind = 0;

    Accuracy staged = Accuracy::not_applicable;   // HEAD against the index
    Accuracy unstaged = Accuracy::not_applicable; // the index against the work tree
    ChangeCounts changes;

    ReadWork work;
  };

  extern template struct Status<Memory>;

}

namespace telar::git {

  enum class Discovered : std::uint8_t {
    repository,
    none,
    not_owned,
    invalid,
    error,
  };

  enum class RefLookup : std::uint8_t {
    found,
    missing,
    invalid,
  };

  struct RepositoryConfig {
    unsigned version = 0;
    ObjectFormat format = ObjectFormat::sha1;
    bool worktree_config = false;
    bool unsupported = false;
    bool bare = false;
    bool file_mode = true;
    bool symlinks = true;
    bool has_worktree = false;
  };

  // The inputs whose fingerprints decide whether a cached part is current.
  struct Inputs {
    Fingerprint head;
    Fingerprint config;
    Fingerprint worktree_config;
    Fingerprint packed_refs;
    Fingerprint branch;
    Fingerprint upstream;
    Fingerprint shallow;

    friend bool operator==(const Inputs&, const Inputs&) = default;
  };

}

export namespace telar::git {

  // Reads repository state for one caller at a time; it is not thread-safe.
  // It keeps the parsed config, packed-refs, index and commit-graph, the last
  // divergence and the HEAD-to-index comparison between reads, and rereads
  // each only when its file's fingerprint changes.
  //
  //   telar::SystemAllocator system;
  //   telar::MemoryAdapter memory{system};
  //   telar::git::StatusReader<telar::Memory> reader{memory};
  //   const auto &status = reader.read("/home/user/project");
  //   if (status.repository == telar::git::RepositoryState::ready && status.head == telar::git::HeadState::branch) {
  //     // status.branch, status.ahead, status.changes.unstaged_modified...
  //   }
  template <Allocator Memory>
  class StatusReader {
  public:
    explicit StatusReader(Memory& memory, Limits limits = {});

    StatusReader(const StatusReader&) = delete;
    StatusReader& operator=(const StatusReader&) = delete;

    // Reads the repository that contains `directory`, an absolute path. Never
    // throws: failures and limits show as unknown parts of the status.
    const Status<Memory>& read(std::string_view directory) noexcept;

    const Status<Memory>& status() const noexcept;

    // The remotes the repository's config names, from the last read().
    template <typename Visit>
    TBC_HOT_PATH void remotes(Visit&& visit) noexcept {
      // Stays generic over the caller's visitor, which the reader calls through a function pointer.
      using Target = std::remove_reference_t<Visit>;

      visitRemotes(const_cast<std::remove_const_t<Target>*>(std::addressof(visit)), [](void* target, std::string_view name) {
        (*static_cast<Target*>(target))(name);
      });
    }

    // stash@{0} to stash@{N}: one per line of the stash's reflog, newest first, at most `limit`.
    std::size_t stashes(std::size_t limit) const noexcept;

    // The local branches of the repository the last read() found: loose refs under refs/heads,
    // then packed ones, each a valid ref name, at most `limit` of them, a name possibly twice.
    // Reads only what it lists; nothing is followed out of the git directory.
    template <typename Visit>
    TBC_HOT_PATH void branches(std::size_t limit, Visit&& visit) const noexcept {
      // Stays generic over the caller's visitor, which the reader calls through a function pointer.
      using Target = std::remove_reference_t<Visit>;

      visitBranches(limit, const_cast<std::remove_const_t<Target>*>(std::addressof(visit)), [](void* target, std::string_view name) {
        (*static_cast<Target*>(target))(name);
      });
    }

    // Whether HEAD, the index, the config, packed-refs, the branch or upstream
    // refs or the shallow file changed since the last read, with one fstatat
    // each and nothing read. Edits to tracked files do not change these: only
    // read() sees them. It assumes the directory still belongs to the same
    // repository; a new or removed .git below it shows only on the next read().
    bool changed() const noexcept;

  private:
    void visitRemotes(void* target, void (*visit)(void*, std::string_view)) noexcept;
    void visitBranches(std::size_t limit, void* target, void (*visit)(void*, std::string_view)) const noexcept;
    void reset(RepositoryState state);

    // Drops every cache that belongs to the previous repository.
    void forget() noexcept;

    Inputs probe() const noexcept;
    Fingerprint referenceFingerprint(std::string_view name) const noexcept;
    void readRepository(std::string_view directory);

    // Walks up from `directory` as git's setup_git_directory does: a .git
    // directory or "gitdir:" file, else the directory itself as a bare git
    // directory. It stops at the filesystem root or a filesystem boundary.
    Discovered discover(std::string_view directory, FileDescriptor& worktree, FileDescriptor& gitdir, FileDescriptor& common) const;

    Discovered readGitFile(FileDescriptor& current, const struct stat& current_status, const struct stat& dot, FileDescriptor& worktree, FileDescriptor& gitdir, FileDescriptor& common) const;

    // Ownership first, then git's is_git_directory: a valid HEAD, and objects/
    // and refs/ in the common directory a linked worktree's commondir names.
    Discovered checkGitDirectory(int directory, FileDescriptor& common) const;

    RepositoryState openConfiguredWorktree();

    // core.* and extensions.* from <common>/config, then config.worktree when
    // extensions.worktreeConfig asks for it. include and includeIf are ignored.
    RepositoryState loadConfig();

    void extension(const ConfigEntry& entry);
    void readReferences();
    void resolveReferences();

    // branch.<name>.remote and .merge, mapped through remote.<remote>.fetch.
    void readUpstream();

    // A loose ref, following symbolic refs, else packed-refs.
    RefLookup resolve(std::string_view name, ObjectId& id, Fingerprint* identity);

    // "<hex> <name>" lines of packed-refs; peeled "^<hex>" lines follow tags.
    RefLookup packedReference(std::string_view name, ObjectId& id) const;

    void readDivergence();
    void readChanges();
    bool compareStaged();

    Memory& memory_;
    Limits limits_;
    Status<Memory> status_;
    FileDescriptor worktree_;
    FileDescriptor gitdir_;

    void looseBranches(int directory, std::string& name, unsigned depth, std::size_t limit, std::size_t& count, void* target, void (*visit)(void*, std::string_view)) const;

    FileDescriptor common_;
    Fingerprint gitdir_identity_;
    Fingerprint common_identity_;
    Inputs inputs_;
    RepositoryConfig config_;
    RepositoryState config_state_ = RepositoryState::ready;
    bool config_loaded_ = false;
    bool staged_current_ = false;
    Accuracy staged_result_ = Accuracy::unknown;
    bool packed_loaded_ = false;
    bool refs_current_ = false;
    ReadStatus packed_state_ = ReadStatus::missing;
    ObjectDatabase<Memory> objects_;
    CommitGraph<Memory> graph_;
    ShallowCommits<Memory> shallow_;
    DivergenceWalk<Memory> walk_;
    Index<Memory> index_;
    StagedComparison<Memory> staged_;
    UnstagedComparison<Memory> unstaged_;
    bool divergence_current_ = false;
    ObjectId divergence_left_;
    ObjectId divergence_right_;
    Accuracy divergence_result_ = Accuracy::unknown;
    Divergence divergence_;
    ObjectId staged_head_;
    Fingerprint staged_index_;
    ChangeCounts staged_counts_;
    String<Memory> config_bytes_;
    String<Memory> worktree_config_bytes_;
    String<Memory> config_scratch_;
    String<Memory> packed_refs_;
    String<Memory> head_reference_;
    String<Memory> upstream_reference_;
    String<Memory> commit_;
    String<Memory> symbolic_{AllocatorRef<char, Memory>{memory_}};
    String<Memory> configured_worktree_{AllocatorRef<char, Memory>{memory_}};
    Vector<ObjectId, Memory> parents_;
  };

  extern template class StatusReader<Memory>;

}
