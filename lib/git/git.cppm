module;
#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>
#include <dirent.h>
#include <unistd.h>

export module telar.git;

import std;
export import telar.base.memory;
import telar.base.text;
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
  none,        // no repository contains the directory
  ready,
  not_owned,   // owned by another user: git's safe.directory default refuses it
  unsupported, // a repository version, extension or ref storage this reader lacks
  invalid,     // a malformed .git file, git directory or config
  unknown      // a system error or a resource limit
};

enum class HeadState : std::uint8_t {
  unknown,
  branch,  // on `branch`, at `head_id`
  unborn,  // on `branch`, which has no commit yet
  detached // at `head_id`
};

enum class UpstreamState : std::uint8_t {
  none,     // no branch.<name>.merge, or detached
  tracking, // `upstream_name` at `upstream_id`
  gone,     // configured, but its remote-tracking ref does not exist
  unknown
};

enum class Accuracy : std::uint8_t {
  exact,
  unknown,       // unreadable data or a limit reached
  unsupported,   // a format this reader lacks, such as a split index
  not_applicable // a bare repository, or no upstream
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
  inline explicit Status(Memory &memory)
      : branch(AllocatorRef<char, Memory>{memory}),
        upstream_name(AllocatorRef<char, Memory>{memory}) {}

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

}

namespace telar::git {

using telar::runtime::asciiEqualIgnoreCase;
using telar::runtime::trimText;

enum class Discovered : std::uint8_t {
  repository,
  none,
  not_owned,
  invalid,
  error
};

enum class RefLookup : std::uint8_t {
  found,
  missing,
  invalid
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

  friend bool operator==(const Inputs &, const Inputs &) = default;
};

inline bool ownedByCaller(const struct stat &status) noexcept {
  return status.st_uid == ::geteuid();
}

// Refs that live in the git directory of each worktree rather than the common one.
inline bool perWorktreeReference(std::string_view name) noexcept {
  return name == "HEAD" || name.starts_with("refs/bisect/") || name.starts_with("refs/worktree/") || name.starts_with("refs/rewritten/");
}

inline std::string_view trimLineEnd(std::string_view text) noexcept {
  while (!text.empty() && (text.back() == '\n' || text.back() == '\r')) {
    text.remove_suffix(1);
  }
  return text;
}

// A fetch refspec's mapping of `reference`, as git's match_name_with_pattern.
inline bool mapRefspec(std::string_view source, std::string_view destination, std::string_view reference, PathName &mapped) noexcept {
  const auto star = source.find('*');
  if (star == std::string_view::npos) {
    return source == reference && mapped.assign({destination});
  }
  const auto prefix = source.substr(0, star);
  const auto suffix = source.substr(star + 1);
  if (reference.size() < prefix.size() + suffix.size() || !reference.starts_with(prefix) || !reference.ends_with(suffix)) {
    return false;
  }
  const auto captured = reference.substr(prefix.size(), reference.size() - prefix.size() - suffix.size());
  const auto target = destination.find('*');
  if (target == std::string_view::npos) {
    return false;
  }
  return mapped.assign({destination.substr(0, target), captured, destination.substr(target + 1)});
}

inline std::string_view shortReference(std::string_view name) noexcept {
  for (const auto prefix : {std::string_view{"refs/heads/"}, std::string_view{"refs/remotes/"}}) {
    if (name.starts_with(prefix)) {
      return name.substr(prefix.size());
    }
  }
  return name;
}

}

export namespace telar::git {

// Reads repository state for one caller at a time; it is not thread-safe.
// It keeps the parsed config, packed-refs, index and commit-graph, the last
// divergence and the HEAD-to-index comparison between reads, and rereads
// each only when its file's fingerprint changes.
//
//   telar::SystemAllocator memory;
//   telar::git::StatusReader reader{memory};
//   const auto &status = reader.read("/home/user/project");
//   if (status.repository == telar::git::RepositoryState::ready && status.head == telar::git::HeadState::branch) {
//     // status.branch, status.ahead, status.changes.unstaged_modified...
//   }
template <Allocator Memory>
class StatusReader {
public:
  inline explicit StatusReader(Memory &memory, Limits limits = {})
      : memory_(memory),
        limits_(limits),
        status_(memory),
        objects_(memory),
        graph_(memory),
        shallow_(memory),
        walk_(memory),
        index_(memory),
        staged_(memory),
        unstaged_(memory),
        config_bytes_(AllocatorRef<char, Memory>{memory}),
        worktree_config_bytes_(AllocatorRef<char, Memory>{memory}),
        config_scratch_(AllocatorRef<char, Memory>{memory}),
        packed_refs_(AllocatorRef<char, Memory>{memory}),
        head_reference_(AllocatorRef<char, Memory>{memory}),
        upstream_reference_(AllocatorRef<char, Memory>{memory}),
        commit_(AllocatorRef<char, Memory>{memory}),
        parents_(AllocatorRef<ObjectId, Memory>{memory}) {}

  StatusReader(const StatusReader &) = delete;
  StatusReader &operator=(const StatusReader &) = delete;

  // Reads the repository that contains `directory`, an absolute path. Never
  // throws: failures and limits show as unknown parts of the status.
  inline const Status<Memory> &read(std::string_view directory) noexcept {
    try {
      readRepository(directory);
    } catch (...) {
      forget();
      reset(RepositoryState::unknown);
    }
    try {
      objects_.trim();
    } catch (...) {
    }
    return status_;
  }

  inline const Status<Memory> &status() const noexcept { return status_; }

  // The remotes the repository's config names, from the last read().
  template <typename Visit>
  inline void remotes(Visit &&visit) noexcept {
    if (status_.repository != RepositoryState::ready) {
      return;
    }
    try {
      static_cast<void>(parseConfig(std::string_view{config_bytes_}, config_scratch_, [&](const ConfigEntry &entry) {
        if (asciiEqualIgnoreCase(entry.section, "remote") && asciiEqualIgnoreCase(entry.key, "url") && !entry.subsection.empty()) {
          visit(entry.subsection);
        }
        return true;
      }));
    } catch (...) {
    }
  }

  // stash@{0} to stash@{N}: one per line of the stash's reflog, newest first, at most `limit`.
  inline std::size_t stashes(std::size_t limit) const noexcept {
    if (status_.repository != RepositoryState::ready || !common_) {
      return 0;
    }
    try {
      String<Memory> log{AllocatorRef<char, Memory>{memory_}};
      if (readWhole(common_.get(), "logs/refs/stash", log, limits_.packed_refs, nullptr) != ReadStatus::ok) {
        return 0;
      }
      return std::min<std::size_t>(limit, static_cast<std::size_t>(std::ranges::count(std::string_view{log}, '\n')));
    } catch (...) {
      return 0;
    }
  }

  // The local branches of the repository the last read() found: loose refs under refs/heads,
  // then packed ones, each a valid ref name, at most `limit` of them, a name possibly twice.
  // Reads only what it lists; nothing is followed out of the git directory.
  template <typename Visit>
  inline void branches(std::size_t limit, Visit &&visit) const noexcept {
    if (status_.repository != RepositoryState::ready || !common_) {
      return;
    }
    std::size_t count = 0;
    try {
      std::string name{"refs/heads"};
      FileDescriptor heads{::openat(common_.get(), "refs/heads", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
      if (heads) {
        looseBranches(heads.get(), name, 0, limit, count, visit);
      }
    } catch (...) {
    }
    if (packed_state_ != ReadStatus::ok) {
      return;
    }
    constexpr std::string_view prefix = "refs/heads/";
    const std::string_view text{packed_refs_};
    for (std::size_t from = 0; from < text.size() && count < limit;) {
      const auto end = std::min(text.find('\n', from), text.size());
      const auto line = trimLineEnd(text.substr(from, end - from));
      from = end + 1;
      const auto space = line.find(' ');
      if (line.starts_with('#') || line.starts_with('^') || space == std::string_view::npos) {
        continue;
      }
      const auto reference = line.substr(space + 1);
      if (reference.starts_with(prefix) && validReferenceName(reference, limits_.path_length)) {
        visit(reference.substr(prefix.size()));
        ++count;
      }
    }
  }

  // Whether HEAD, the index, the config, packed-refs, the branch or upstream
  // refs or the shallow file changed since the last read, with one fstatat
  // each and nothing read. Edits to tracked files do not change these: only
  // read() sees them. It assumes the directory still belongs to the same
  // repository; a new or removed .git below it shows only on the next read().
  inline bool changed() const noexcept {
    if (!gitdir_ || status_.repository != RepositoryState::ready) {
      return true;
    }
    return probe() != inputs_ || (worktree_ && fingerprintAt(gitdir_.get(), "index") != index_.fingerprint);
  }

private:
  inline void reset(RepositoryState state) {
    status_.repository = state;
    status_.bare = false;
    status_.linked_worktree = false;
    status_.head = HeadState::unknown;
    status_.branch.clear();
    status_.head_id = {};
    status_.upstream = UpstreamState::none;
    status_.upstream_name.clear();
    status_.upstream_id = {};
    status_.divergence = Accuracy::not_applicable;
    status_.ahead = 0;
    status_.behind = 0;
    status_.staged = Accuracy::not_applicable;
    status_.unstaged = Accuracy::not_applicable;
    status_.changes = {};
  }

  // Drops every cache that belongs to the previous repository.
  inline void forget() noexcept {
    worktree_.reset();
    gitdir_.reset();
    common_.reset();
    gitdir_identity_ = {};
    common_identity_ = {};
    inputs_ = {};
    config_loaded_ = false;
    packed_loaded_ = false;
    staged_current_ = false;
    divergence_current_ = false;
    staged_head_ = {};
    staged_index_ = {};
    objects_.close();
    graph_.clear();
    refs_current_ = false;
  }

  inline Inputs probe() const noexcept {
    Inputs inputs;
    inputs.head = fingerprintAt(gitdir_.get(), "HEAD");
    inputs.config = fingerprintAt(common_.get(), "config");
    inputs.worktree_config = config_.worktree_config ? fingerprintAt(gitdir_.get(), "config.worktree") : Fingerprint{};
    inputs.packed_refs = fingerprintAt(common_.get(), "packed-refs");
    inputs.branch = referenceFingerprint(head_reference_);
    inputs.upstream = referenceFingerprint(upstream_reference_);
    inputs.shallow = fingerprintAt(common_.get(), "shallow");
    return inputs;
  }

  inline Fingerprint referenceFingerprint(std::string_view name) const noexcept {
    PathName path;
    if (name.empty() || !path.assign({name})) {
      return {};
    }
    return fingerprintAt(perWorktreeReference(name) ? gitdir_.get() : common_.get(), path.c_str());
  }

  inline void readRepository(std::string_view directory) {
    status_.work = {};
    objects_.objects_read = 0;
    walk_.commits_read = 0;
    staged_.trees_read = 0;
    unstaged_.entries_checked = 0;
    unstaged_.files_hashed = 0;
    unstaged_.bytes_hashed = 0;

    FileDescriptor worktree;
    FileDescriptor gitdir;
    FileDescriptor common;
    switch (discover(directory, worktree, gitdir, common)) {
    case Discovered::repository:
      break;
    case Discovered::none:
      forget();
      reset(RepositoryState::none);
      return;
    case Discovered::not_owned:
      forget();
      reset(RepositoryState::not_owned);
      return;
    case Discovered::invalid:
      forget();
      reset(RepositoryState::invalid);
      return;
    case Discovered::error:
      forget();
      reset(RepositoryState::unknown);
      return;
    }

    struct stat gitdir_status{};
    struct stat common_status{};
    if (::fstat(gitdir.get(), &gitdir_status) != 0 || ::fstat(common.get(), &common_status) != 0) {
      forget();
      reset(RepositoryState::unknown);
      return;
    }
    const auto gitdir_identity = fingerprintOf(gitdir_status);
    const auto common_identity = fingerprintOf(common_status);
    if (gitdir_identity.device != gitdir_identity_.device || gitdir_identity.inode != gitdir_identity_.inode ||
        common_identity.device != common_identity_.device || common_identity.inode != common_identity_.inode) {
      forget();
      gitdir_identity_ = gitdir_identity;
      common_identity_ = common_identity;
    }
    worktree_ = std::move(worktree);
    gitdir_ = std::move(gitdir);
    common_ = std::move(common);
    status_.linked_worktree = !sameFile(gitdir_status, common_status);

    if (const auto state = loadConfig(); state != RepositoryState::ready) {
      refs_current_ = false;
      reset(state);
      return;
    }
    if (config_.bare) {
      worktree_.reset();
    } else if (config_.has_worktree && !status_.linked_worktree) {
      if (const auto state = openConfiguredWorktree(); state != RepositoryState::ready) {
        refs_current_ = false;
        reset(state);
        return;
      }
    }
    status_.repository = RepositoryState::ready;
    status_.format = config_.format;
    status_.bare = !worktree_;

    if (!objects_.open(common_.get(), config_.format, limits_)) {
      refs_current_ = false;
      reset(RepositoryState::invalid);
      return;
    }
    const auto inputs = probe();
    if (!refs_current_ || inputs != inputs_) {
      readReferences();
    }
    readDivergence();
    readChanges();

    status_.work.objects_read = objects_.objects_read;
    status_.work.commits_read = walk_.commits_read;
    status_.work.trees_read = staged_.trees_read;
    status_.work.entries_checked = unstaged_.entries_checked;
    status_.work.files_hashed = unstaged_.files_hashed;
    status_.work.bytes_hashed = unstaged_.bytes_hashed;
  }

  // Walks up from `directory` as git's setup_git_directory does: a .git
  // directory or "gitdir:" file, else the directory itself as a bare git
  // directory. It stops at the filesystem root or a filesystem boundary.
  inline Discovered discover(std::string_view directory, FileDescriptor &worktree, FileDescriptor &gitdir, FileDescriptor &common) const {
    PathName start;
    if (directory.empty() || directory.front() != '/' || !start.assign({directory})) {
      return Discovered::error;
    }
    FileDescriptor current{::open(start.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
    if (!current) {
      return errno == ENOENT || errno == ENOTDIR ? Discovered::none : Discovered::error;
    }
    struct stat current_status{};
    if (::fstat(current.get(), &current_status) != 0) {
      return Discovered::error;
    }
    const auto device = current_status.st_dev;
    for (std::size_t depth = 0; depth < limits_.discovery_depth; ++depth) {
      struct stat dot{};
      if (::fstatat(current.get(), ".git", &dot, 0) == 0) {
        if (S_ISDIR(dot.st_mode)) {
          auto candidate = openDirectory(current.get(), ".git");
          if (!candidate) {
            return Discovered::error;
          }
          if (looksLikeGitDirectory(candidate.get())) {
            if (!ownedByCaller(current_status)) {
              return Discovered::not_owned;
            }
            const auto checked = checkGitDirectory(candidate.get(), common);
            if (checked == Discovered::repository) {
              worktree = std::move(current);
              gitdir = std::move(candidate);
            }
            return checked;
          }
        } else if (S_ISREG(dot.st_mode)) {
          return readGitFile(current, current_status, dot, worktree, gitdir, common);
        } else {
          return Discovered::invalid;
        }
      } else if (errno != ENOENT && errno != ENOTDIR) {
        return Discovered::error;
      }

      if (looksLikeGitDirectory(current.get())) {
        const auto checked = checkGitDirectory(current.get(), common);
        if (checked == Discovered::repository) {
          gitdir = std::move(current);
        }
        return checked;
      }

      auto parent = openDirectory(current.get(), "..");
      struct stat parent_status{};
      if (!parent || ::fstat(parent.get(), &parent_status) != 0) {
        return Discovered::error;
      }
      if (sameFile(parent_status, current_status) || parent_status.st_dev != device) {
        return Discovered::none;
      }
      current = std::move(parent);
      current_status = parent_status;
    }
    return Discovered::none;
  }

  inline Discovered readGitFile(FileDescriptor &current, const struct stat &current_status, const struct stat &dot, FileDescriptor &worktree, FileDescriptor &gitdir, FileDescriptor &common) const {
    if (!ownedByCaller(current_status) || !ownedByCaller(dot)) {
      return Discovered::not_owned;
    }
    std::array<char, 4096> bytes;
    std::string_view contents;
    if (readSmall(current.get(), ".git", std::span{bytes}.first(std::min(bytes.size(), limits_.small_file)), contents) != ReadStatus::ok) {
      return Discovered::invalid;
    }
    contents = trimLineEnd(contents);
    constexpr std::string_view prefix = "gitdir:";
    if (!contents.starts_with(prefix)) {
      return Discovered::invalid;
    }
    const auto target = trimText(contents.substr(prefix.size()), " \t");
    PathName path;
    if (target.empty() || !path.assign({target})) {
      return Discovered::invalid;
    }
    auto candidate = openDirectory(current.get(), path.c_str());
    if (!candidate || !looksLikeGitDirectory(candidate.get())) {
      return Discovered::invalid;
    }
    const auto checked = checkGitDirectory(candidate.get(), common);
    if (checked == Discovered::repository) {
      worktree = std::move(current);
      gitdir = std::move(candidate);
    }
    return checked;
  }

  // HEAD and either commondir or objects/ and refs/, before anything is read.
  inline static bool looksLikeGitDirectory(int directory) noexcept {
    struct stat status{};
    if (::fstatat(directory, "HEAD", &status, AT_SYMLINK_NOFOLLOW) != 0 || !S_ISREG(status.st_mode)) {
      return false;
    }
    if (::fstatat(directory, "commondir", &status, AT_SYMLINK_NOFOLLOW) == 0 && S_ISREG(status.st_mode)) {
      return true;
    }
    return ::fstatat(directory, "objects", &status, 0) == 0 && S_ISDIR(status.st_mode) && ::fstatat(directory, "refs", &status, 0) == 0 && S_ISDIR(status.st_mode);
  }

  // Ownership first, then git's is_git_directory: a valid HEAD, and objects/
  // and refs/ in the common directory a linked worktree's commondir names.
  inline Discovered checkGitDirectory(int directory, FileDescriptor &common) const {
    struct stat status{};
    if (::fstat(directory, &status) != 0) {
      return Discovered::error;
    }
    if (!ownedByCaller(status)) {
      return Discovered::not_owned;
    }
    std::array<char, 4096> bytes;
    std::string_view contents;
    const auto small = std::span{bytes}.first(std::min(bytes.size(), limits_.small_file));
    const auto common_file = readSmall(directory, "commondir", small, contents);
    if (common_file == ReadStatus::ok) {
      PathName path;
      const auto target = trimLineEnd(contents);
      if (target.empty() || !path.assign({target})) {
        return Discovered::invalid;
      }
      common = openDirectory(directory, path.c_str());
    } else if (common_file == ReadStatus::missing) {
      common = openDirectory(directory, ".");
    } else {
      return Discovered::invalid;
    }
    if (!common) {
      return Discovered::invalid;
    }
    if (::fstat(common.get(), &status) != 0) {
      return Discovered::error;
    }
    if (!ownedByCaller(status)) {
      return Discovered::not_owned;
    }
    if (readSmall(directory, "HEAD", small, contents) != ReadStatus::ok) {
      return Discovered::invalid;
    }
    contents = trimLineEnd(contents);
    const bool symbolic = contents.starts_with("ref:") && trimText(contents.substr(4), " \t").starts_with("refs/");
    if (!symbolic && !ObjectId::fromHex(contents, ObjectFormat::sha1) && !ObjectId::fromHex(contents, ObjectFormat::sha256)) {
      return Discovered::invalid;
    }
    if (::fstatat(common.get(), "objects", &status, 0) != 0 || !S_ISDIR(status.st_mode) || ::fstatat(common.get(), "refs", &status, 0) != 0 || !S_ISDIR(status.st_mode)) {
      return Discovered::invalid;
    }
    return Discovered::repository;
  }

  inline RepositoryState openConfiguredWorktree() {
    PathName path;
    if (configured_worktree_.empty() || !path.assign({configured_worktree_})) {
      return RepositoryState::invalid;
    }
    auto directory = openDirectory(gitdir_.get(), path.c_str());
    struct stat status{};
    if (!directory || ::fstat(directory.get(), &status) != 0) {
      return RepositoryState::invalid;
    }
    if (!ownedByCaller(status)) {
      return RepositoryState::not_owned;
    }
    worktree_ = std::move(directory);
    return RepositoryState::ready;
  }

  // core.* and extensions.* from <common>/config, then config.worktree when
  // extensions.worktreeConfig asks for it. include and includeIf are ignored.
  inline RepositoryState loadConfig() {
    const auto identity = fingerprintAt(common_.get(), "config");
    const auto worktree_identity = fingerprintAt(gitdir_.get(), "config.worktree");
    if (config_loaded_ && identity == inputs_.config && (!config_.worktree_config || worktree_identity == inputs_.worktree_config)) {
      return config_state_;
    }
    config_loaded_ = true;
    refs_current_ = false;
    config_ = {};
    configured_worktree_.clear();
    config_state_ = RepositoryState::ready;
    Fingerprint read_identity;
    const auto read = readWhole(common_.get(), "config", config_bytes_, limits_.config_file, &read_identity);
    inputs_.config = read_identity;
    if (read == ReadStatus::invalid) {
      config_state_ = RepositoryState::invalid;
      return config_state_;
    }
    bool valid = true;
    const auto visit = [&](bool worktree_file) {
      return [&, worktree_file](const ConfigEntry &entry) {
        if (asciiEqualIgnoreCase(entry.section, "core") && entry.subsection.empty()) {
          if (asciiEqualIgnoreCase(entry.key, "repositoryformatversion") && !worktree_file) {
            const auto version = entry.value ? telar::runtime::unsignedDecimal<unsigned>(*entry.value) : std::nullopt;
            valid = valid && version.has_value();
            config_.version = version.value_or(0);
          } else if (asciiEqualIgnoreCase(entry.key, "bare")) {
            const auto value = configBoolean(entry.value);
            valid = valid && value.has_value();
            config_.bare = value.value_or(false);
          } else if (asciiEqualIgnoreCase(entry.key, "filemode")) {
            const auto value = configBoolean(entry.value);
            valid = valid && value.has_value();
            config_.file_mode = value.value_or(true);
          } else if (asciiEqualIgnoreCase(entry.key, "symlinks")) {
            const auto value = configBoolean(entry.value);
            valid = valid && value.has_value();
            config_.symlinks = value.value_or(true);
          } else if (asciiEqualIgnoreCase(entry.key, "worktree") && entry.value) {
            config_.has_worktree = true;
            configured_worktree_.assign(*entry.value);
          }
        } else if (asciiEqualIgnoreCase(entry.section, "extensions") && entry.subsection.empty() && !worktree_file) {
          extension(entry);
        }
        return true;
      };
    };
    if (read == ReadStatus::ok && !parseConfig(std::string_view{config_bytes_}, config_scratch_, visit(false))) {
      valid = false;
    }
    if (valid && config_.version == 0) {
      // Repository format 0 ignores extensions, except that it honours worktreeConfig.
      config_.format = ObjectFormat::sha1;
      config_.unsupported = false;
    }
    if (valid && config_.worktree_config) {
      const auto worktree_read = readWhole(gitdir_.get(), "config.worktree", worktree_config_bytes_, limits_.config_file, &inputs_.worktree_config);
      if (worktree_read == ReadStatus::invalid ||
          (worktree_read == ReadStatus::ok && !parseConfig(std::string_view{worktree_config_bytes_}, config_scratch_, visit(true)))) {
        valid = false;
      }
    } else {
      inputs_.worktree_config = {};
    }
    if (!valid) {
      config_state_ = RepositoryState::invalid;
    } else if (config_.version > 1 || config_.unsupported) {
      config_state_ = RepositoryState::unsupported;
    }
    return config_state_;
  }

  inline void extension(const ConfigEntry &entry) {
    const auto value = entry.value.value_or("");
    if (asciiEqualIgnoreCase(entry.key, "objectformat")) {
      if (asciiEqualIgnoreCase(value, "sha1")) {
        config_.format = ObjectFormat::sha1;
      } else if (asciiEqualIgnoreCase(value, "sha256")) {
        config_.format = ObjectFormat::sha256;
      } else {
        config_.unsupported = true;
      }
    } else if (asciiEqualIgnoreCase(entry.key, "refstorage")) {
      config_.unsupported = config_.unsupported || !asciiEqualIgnoreCase(value, "files");
    } else if (asciiEqualIgnoreCase(entry.key, "worktreeconfig")) {
      config_.worktree_config = configBoolean(entry.value).value_or(false);
    } else {
      // Extensions that change nothing this reader reads; any other is unknown to it.
      bool known = false;
      for (const auto name : {"noop", "noop-v1", "preciousobjects", "partialclone", "compatobjectformat", "relativeworktrees", "submodulepathconfig"}) {
        known = known || asciiEqualIgnoreCase(entry.key, name);
      }
      config_.unsupported = config_.unsupported || !known;
    }
  }

  inline void readReferences() {
    resolveReferences();
    // A large packed-refs is read again when a ref changes rather than kept.
    constexpr std::size_t retained = 1 << 20;
    if (packed_refs_.capacity() > retained) {
      packed_refs_.clear();
      packed_refs_.shrink_to_fit();
      packed_loaded_ = false;
    }
  }

  inline void resolveReferences() {
    refs_current_ = true;
    status_.head = HeadState::unknown;
    status_.branch.clear();
    status_.head_id = {};
    status_.upstream = UpstreamState::none;
    status_.upstream_name.clear();
    status_.upstream_id = {};
    head_reference_.clear();
    upstream_reference_.clear();
    inputs_.branch = {};
    inputs_.upstream = {};
    inputs_.shallow = fingerprintAt(common_.get(), "shallow");

    std::array<char, 4096> bytes;
    std::string_view contents;
    const auto small = std::span{bytes}.first(std::min(bytes.size(), limits_.small_file));
    const auto packed = fingerprintAt(common_.get(), "packed-refs");
    if (!packed_loaded_ || packed != inputs_.packed_refs) {
      packed_loaded_ = true;
      packed_state_ = readWhole(common_.get(), "packed-refs", packed_refs_, limits_.packed_refs, &inputs_.packed_refs);
      if (packed_state_ == ReadStatus::missing) {
        inputs_.packed_refs = {};
      }
    }
    if (readSmall(gitdir_.get(), "HEAD", small, contents, &inputs_.head) != ReadStatus::ok) {
      inputs_.head = {};
      return;
    }
    contents = trimLineEnd(contents);
    if (!contents.starts_with("ref:")) {
      if (const auto id = ObjectId::fromHex(contents, config_.format)) {
        status_.head = HeadState::detached;
        status_.head_id = *id;
      }
      return;
    }
    const auto target = trimText(contents.substr(4), " \t");
    if (!target.starts_with("refs/") || !validReferenceName(target, limits_.path_length)) {
      return;
    }
    head_reference_.assign(target);
    status_.branch.assign(target.starts_with("refs/heads/") ? target.substr(11) : target);
    switch (resolve(head_reference_, status_.head_id, &inputs_.branch)) {
    case RefLookup::found:
      status_.head = HeadState::branch;
      break;
    case RefLookup::missing:
      status_.head = HeadState::unborn;
      break;
    case RefLookup::invalid:
      status_.head = HeadState::unknown;
      return;
    }
    readUpstream();
  }

  // branch.<name>.remote and .merge, mapped through remote.<remote>.fetch.
  inline void readUpstream() {
    if (!head_reference_.starts_with("refs/heads/")) {
      return;
    }
    const std::string_view branch{status_.branch};
    PathName remote;
    PathName merge;
    bool have_remote = false;
    bool have_merge = false;
    bool valid = true;
    const auto branches = [&](const ConfigEntry &entry) {
      if (!asciiEqualIgnoreCase(entry.section, "branch") || entry.subsection != branch || !entry.value) {
        return true;
      }
      if (asciiEqualIgnoreCase(entry.key, "remote")) {
        have_remote = remote.assign({*entry.value});
        valid = valid && have_remote;
      } else if (asciiEqualIgnoreCase(entry.key, "merge") && !have_merge) {
        // git tracks the first merge value of a branch.
        have_merge = merge.assign({*entry.value});
        valid = valid && have_merge;
      }
      return true;
    };
    if (!parseConfig(std::string_view{config_bytes_}, config_scratch_, branches) ||
        (config_.worktree_config && !parseConfig(std::string_view{worktree_config_bytes_}, config_scratch_, branches)) || !valid) {
      status_.upstream = UpstreamState::unknown;
      return;
    }
    if (!have_merge || !have_remote || remote.view().empty()) {
      return;
    }
    if (!merge.view().starts_with("refs/") || !validReferenceName(merge.view(), limits_.path_length)) {
      status_.upstream = UpstreamState::unknown;
      return;
    }
    PathName tracking;
    if (remote.view() == ".") {
      tracking.assign({merge.view()});
    } else {
      bool matched = false;
      bool excluded = false;
      const auto remotes = [&](const ConfigEntry &entry) {
        if (!asciiEqualIgnoreCase(entry.section, "remote") || entry.subsection != remote.view() || !asciiEqualIgnoreCase(entry.key, "fetch") || !entry.value) {
          return true;
        }
        auto spec = *entry.value;
        if (spec.starts_with('^')) {
          spec.remove_prefix(1);
          PathName ignored;
          excluded = excluded || (spec.contains('*') ? mapRefspec(spec, "*", merge.view(), ignored) : spec == merge.view());
          return true;
        }
        if (spec.starts_with('+')) {
          spec.remove_prefix(1);
        }
        const auto colon = spec.find(':');
        if (!matched && colon != std::string_view::npos) {
          matched = mapRefspec(spec.substr(0, colon), spec.substr(colon + 1), merge.view(), tracking);
        }
        return true;
      };
      if (!parseConfig(std::string_view{config_bytes_}, config_scratch_, remotes)) {
        status_.upstream = UpstreamState::unknown;
        return;
      }
      if (!matched || excluded) {
        return;
      }
    }
    if (!validReferenceName(tracking.view(), limits_.path_length)) {
      status_.upstream = UpstreamState::unknown;
      return;
    }
    upstream_reference_.assign(tracking.view());
    status_.upstream_name.assign(shortReference(tracking.view()));
    switch (resolve(upstream_reference_, status_.upstream_id, &inputs_.upstream)) {
    case RefLookup::found:
      status_.upstream = UpstreamState::tracking;
      break;
    case RefLookup::missing:
      status_.upstream = UpstreamState::gone;
      break;
    case RefLookup::invalid:
      status_.upstream = UpstreamState::unknown;
      break;
    }
  }

  // A loose ref, following symbolic refs, else packed-refs.
  inline RefLookup resolve(std::string_view name, ObjectId &id, Fingerprint *identity) {
    for (std::size_t depth = 0; depth <= limits_.symbolic_depth; ++depth) {
      PathName path;
      if (!validReferenceName(name, limits_.path_length) || !path.assign({name})) {
        return RefLookup::invalid;
      }
      std::array<char, 4096> bytes;
      std::string_view contents;
      Fingerprint loose;
      const auto read = readSmall(perWorktreeReference(name) ? gitdir_.get() : common_.get(), path.c_str(), std::span{bytes}.first(std::min(bytes.size(), limits_.small_file)), contents, &loose);
      if (depth == 0 && identity != nullptr) {
        *identity = read == ReadStatus::ok ? loose : Fingerprint{};
      }
      if (read == ReadStatus::invalid) {
        return RefLookup::invalid;
      }
      if (read == ReadStatus::missing) {
        return packedReference(name, id);
      }
      contents = trimLineEnd(contents);
      if (contents.starts_with("ref:")) {
        const auto target = trimText(contents.substr(4), " \t");
        if (!target.starts_with("refs/")) {
          return RefLookup::invalid;
        }
        symbolic_.assign(target);
        name = symbolic_;
        continue;
      }
      const auto parsed = ObjectId::fromHex(trimText(contents, " \t"), config_.format);
      if (!parsed) {
        return RefLookup::invalid;
      }
      id = *parsed;
      return RefLookup::found;
    }
    return RefLookup::invalid;
  }

  // "<hex> <name>" lines of packed-refs; peeled "^<hex>" lines follow tags.
  inline RefLookup packedReference(std::string_view name, ObjectId &id) const {
    if (packed_state_ == ReadStatus::missing) {
      return RefLookup::missing;
    }
    if (packed_state_ != ReadStatus::ok) {
      return RefLookup::invalid;
    }
    const std::string_view text{packed_refs_};
    const auto digits = 2 * hashSize(config_.format);
    for (std::size_t from = 0;;) {
      const auto found = text.find(name, from);
      if (found == std::string_view::npos) {
        return RefLookup::missing;
      }
      from = found + 1;
      const auto after = found + name.size();
      if (found < digits + 1 || text[found - 1] != ' ' || (after < text.size() && text[after] != '\n' && text[after] != '\r')) {
        continue;
      }
      const auto line = found - digits - 1;
      if (line != 0 && text[line - 1] != '\n') {
        continue;
      }
      const auto parsed = ObjectId::fromHex(text.substr(line, digits), config_.format);
      if (!parsed) {
        return RefLookup::invalid;
      }
      id = *parsed;
      return RefLookup::found;
    }
  }

  inline void readDivergence() {
    if (status_.upstream != UpstreamState::tracking || status_.head != HeadState::branch) {
      status_.divergence = status_.upstream == UpstreamState::unknown || status_.head == HeadState::unknown ? Accuracy::unknown : Accuracy::not_applicable;
      status_.ahead = 0;
      status_.behind = 0;
      return;
    }
    // Commits never change, so a divergence holds while both tips do. A failed
    // walk is kept as well, so a limit is not hit again on every read.
    if (!divergence_current_ || status_.head_id != divergence_left_ || status_.upstream_id != divergence_right_) {
      divergence_current_ = true;
      divergence_left_ = status_.head_id;
      divergence_right_ = status_.upstream_id;
      divergence_result_ = Accuracy::unknown;
      divergence_ = {};
      if (shallow_.load(common_.get(), config_.format, limits_)) {
        // git ignores the commit-graph of a shallow clone, whose parents it rewrites.
        graph_.load(objects_.objects(), config_.format, limits_, !shallow_.empty());
        if (const auto counted = walk_.count(objects_, graph_, shallow_, limits_, status_.head_id, status_.upstream_id)) {
          divergence_result_ = Accuracy::exact;
          divergence_ = *counted;
        }
      }
    }
    status_.divergence = divergence_result_;
    status_.ahead = divergence_.ahead;
    status_.behind = divergence_.behind;
  }

  inline void readChanges() {
    if (!worktree_) {
      status_.staged = Accuracy::not_applicable;
      status_.unstaged = Accuracy::not_applicable;
      status_.changes = {};
      return;
    }
    const auto state = index_.load(gitdir_.get(), config_.format, limits_);
    if (state != IndexState::ready) {
      status_.staged = state == IndexState::unsupported ? Accuracy::unsupported : Accuracy::unknown;
      status_.unstaged = status_.staged;
      status_.changes = {};
      staged_current_ = false;
      return;
    }
    if (status_.head == HeadState::unknown) {
      status_.staged = Accuracy::unknown;
      staged_current_ = false;
    } else if (!staged_current_ || status_.head_id != staged_head_ || index_.fingerprint != staged_index_) {
      // A failed comparison is cached too, so a limit is not hit again on every read.
      staged_counts_ = {};
      staged_result_ = compareStaged() ? Accuracy::exact : Accuracy::unknown;
      staged_current_ = true;
      staged_head_ = status_.head_id;
      staged_index_ = index_.fingerprint;
      status_.staged = staged_result_;
    } else {
      status_.staged = staged_result_;
    }
    ChangeCounts counts;
    status_.unstaged = unstaged_.compare(worktree_.get(), index_, {config_.format, config_.file_mode, config_.symlinks}, limits_, counts) ? Accuracy::exact : Accuracy::unknown;
    status_.changes = status_.unstaged == Accuracy::exact ? counts : ChangeCounts{};
    if (status_.staged == Accuracy::exact) {
      status_.changes.staged_added = staged_counts_.staged_added;
      status_.changes.staged_modified = staged_counts_.staged_modified;
      status_.changes.staged_deleted = staged_counts_.staged_deleted;
    }
  }

  inline bool compareStaged() {
    std::optional<ObjectId> tree;
    if (status_.head_id) {
      ObjectType type = ObjectType::none;
      CommitHeader header;
      parents_.clear();
      if (objects_.read(status_.head_id, type, commit_, limits_.commit_header) != Lookup::found || type != ObjectType::commit ||
          !parseCommit(commit_, config_.format, limits_.commit_parents, header, parents_)) {
        return false;
      }
      tree = header.tree;
    }
    return staged_.compare(objects_, index_, tree, limits_, staged_counts_);
  }

  Memory &memory_;
  Limits limits_;
  Status<Memory> status_;
  FileDescriptor worktree_;
  FileDescriptor gitdir_;
  template <typename Visit>
  inline void looseBranches(int directory, std::string &name, unsigned depth, std::size_t limit, std::size_t &count, Visit &visit) const {
    constexpr unsigned maximum_depth = 16;
    runtime::DirectoryStream entries{directory};
    while (const auto *entry = entries.next()) {
      if (count >= limit) {
        return;
      }
      const std::string_view child{entry->d_name};
      if (child == "." || child == "..") {
        continue;
      }
      struct stat state{};
      if (::fstatat(directory, entry->d_name, &state, AT_SYMLINK_NOFOLLOW) != 0) {
        continue;
      }
      const auto size = name.size();
      name.push_back('/');
      name.append(child);
      if (S_ISDIR(state.st_mode) && depth < maximum_depth) {
        FileDescriptor nested{::openat(directory, entry->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
        if (nested) {
          looseBranches(nested.get(), name, depth + 1, limit, count, visit);
        }
      } else if (S_ISREG(state.st_mode) && validReferenceName(name, limits_.path_length)) {
        visit(std::string_view{name}.substr(std::string_view{"refs/heads/"}.size()));
        ++count;
      }
      name.resize(size);
    }
  }

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

}
