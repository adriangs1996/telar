module;
#include "tbc/view.hpp"
#include <stdlib.h>

#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>
#include <cstdlib>
#include <limits.h>
#if (defined(__APPLE__))
#include <mach-o/dyld.h>
#endif
#include <fcntl.h>
#include <sys/stat.h>
#include <csignal>
#include <dirent.h>
#include <spawn.h>
#include <sys/wait.h>
#include <cstdio>
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__))
#include <sys/syscall.h>
#endif
#include <cassert>
#include <sys/types.h>
#include <poll.h>
#include <climits>
#include <dlfcn.h>
#include <openssl/sha.h>

#include <sys/file.h>

#include <signal.h>
#include <new>

#include <pwd.h>


#include <cmath>


export module telar.cli.worktree;

import std;

export import telar.cli.history;
export import telar.cli.worktree_git;
export import telar.cli.tab;


export import telar.cli.command_limit;


export import telar.platform;


export import telar.cli.machine_ssh;
export import telar.base.text;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;

// Interface: repository_discovery.cppm
export {
namespace telar::runtime::cli::repository {

struct Catalog {
  std::vector<std::pair<std::uint64_t, std::string>> workspaces;
  std::vector<std::string> worktrees;
};

template <Allocator Memory>
Catalog catalog(Memory &memory, const char *socket) {
  RuntimeConnection connection{socket};
  connection.receiveTimeout(30);
  std::array<Byte, 32> outgoing;
  connection.send(RequestRuntimeState{.client_identity = randomIdentity(), .interactive = false}, outgoing);
  Vector<Byte, Memory> incoming(max_payload_size, Byte{}, AllocatorRef<Byte, Memory>{memory});
  Vector<Byte, Memory> decoded(max_payload_size, Byte{}, AllocatorRef<Byte, Memory>{memory});
  for (;;) {
    const auto frame = connection.receive(incoming);
    if (static_cast<ServerTag>(frame.front()) != ServerTag::workspace_list) {
      continue;
    }

    DecodeStorage storage{decoded};
    const auto list = Codec::decode<WorkspaceList>(frame, storage);
    Catalog result;
    for (const auto &entry : list.entries) {
      result.workspaces.emplace_back(entry.workspace, entry.path);
    }

    for (const auto &entry : list.worktrees) {
      result.worktrees.emplace_back(entry.path);
    }

    return result;
  }
}

inline std::string managedPath(std::string_view identity) {
  const ProcessEnvironment environment;
  // A later lookup may overwrite the storage an earlier one returned.
  const std::string home{environment.lookup("HOME")};
  if (home.empty()) {
    throw std::runtime_error{"HomeDirectoryUnavailable"};
  }

  const auto configured = environment.lookup("XDG_DATA_HOME");
  const auto base = configured.empty() ? std::string{home} + "/.local/share" : std::string{configured};
  if (!base.starts_with('/')) {
    throw std::runtime_error{"InvalidDataDirectory"};
  }

  std::array<unsigned char, SHA256_DIGEST_LENGTH> digest;
  ::SHA256(reinterpret_cast<const unsigned char *>(identity.data()), identity.size(), digest.data());
  auto result = base + "/telar/repositories/";
  for (const auto byte : digest) {
    result += std::format("{:02x}", byte);
  }

  return result;
}

template <Allocator Memory>
std::string mainRoot(Memory &memory, std::string_view path) {
  Git git{memory, path};
  const auto common = git.read({"rev-parse", "--path-format=absolute", "--git-common-dir"});
  auto trimmed = std::string_view{common};
  while (trimmed.ends_with('/')) {
    trimmed.remove_suffix(1);
  }

  constexpr std::string_view suffix = "/.git";
  if (!trimmed.ends_with(suffix)) {
    throw std::runtime_error{"NotARepository"};
  }

  trimmed.remove_suffix(suffix.size());
  if (trimmed.empty() || !trimmed.starts_with('/')) {
    throw std::runtime_error{"NotARepository"};
  }

  return std::string{trimmed};
}

template <Allocator Memory>
std::optional<std::string> matching(Memory &memory, std::string_view path, std::string_view identity) {
  if (path.contains('\0') || path.size() >= PATH_MAX) {
    return std::nullopt;
  }

  std::string root;
  try {
    root = mainRoot(memory, path);
  } catch (const std::exception &) {
    return std::nullopt;
  }

  auto directory = file_transfer::openDirectory(root);
  try {
    Git git{memory, root};
    if (normalize(git.read({"config", "--get", "remote.origin.url"})) != identity) {
      return std::nullopt;
    }
  } catch (const std::exception &) {
    return std::nullopt;
  }

  return root;
}

// Repository discovery: the main checkout whose origin is
// `identity` among the runtime's workspaces and worktrees, the workspaces
// history recorded and the managed clone. It starts the runtime if needed.
template <Allocator Memory>
std::optional<std::string> find(Memory &memory, std::string_view identity, std::optional<std::string_view> selected, std::optional<std::string_view> socket = std::nullopt) {
  const ProcessEnvironment environment;
  ServerOptions server;
  if (socket) {
    server.socket = *socket;
  }

  const RuntimePaths paths{memory, server, environment};
  ensureRuntime(memory, paths);
  const auto available = catalog(memory, paths.socket.c_str());
  if (selected) {
    std::string path{*selected};
    if (const auto id = maybeUnsigned(*selected)) {
      const auto found = std::ranges::find(available.workspaces, *id, &std::pair<std::uint64_t, std::string>::first);
      if (found == available.workspaces.end()) {
        throw std::runtime_error{"WorkspaceNotFound"};
      }

      path = found->second;
    }

    auto result = matching(memory, path, identity);
    if (!result) {
      throw std::runtime_error{"RepositoryNotInWorkspace"};
    }

    return result;
  }

  std::optional<std::string> result;
  auto consider = [&](std::string_view path) {
    const auto candidate = matching(memory, path, identity);
    if (!candidate) {
      return;
    }

    if (result && result != candidate) {
      throw std::runtime_error{"AmbiguousRepository"};
    }

    result = candidate;
  };
  for (const auto &[id, path] : available.workspaces) {
    consider(path);
  }

  for (const auto &path : available.worktrees) {
    consider(path);
  }

  RuntimePaths storage_paths{memory, ServerOptions{}, environment};
  storage_paths.resolveStorage(ServerOptions{}, environment);
  historyPaths(storage_paths.history.c_str(), consider);

  consider(managedPath(identity));
  return result;
}

}
}

// Interface: repository_options.cppm
export {
namespace telar::runtime::cli {

struct RepositoryOptions {
  enum class Action {
    prepare,
    receive,
    tips
  };
  Action action;
  std::optional<std::string_view> machine = std::nullopt;
  std::string_view from = "HEAD";
  std::optional<std::string_view> workspace = std::nullopt;
  std::string_view identity;
  std::string_view transport;
  std::string_view commit;
  std::string_view ref;
  std::uint64_t bytes = 0;
  bool json = false;

  inline static RepositoryOptions parse(Arguments words) {
    if (words.empty()) {
      throw std::invalid_argument{"MissingRepositoryAction"};
    }

    const std::string_view action = words.front();
    if (action != "prepare" && action != "receive" && action != "tips") {
      throw std::invalid_argument{"UnknownRepositoryAction"};
    }

    RepositoryOptions self{.action = action == "prepare" ? Action::prepare : action == "receive" ? Action::receive : Action::tips};
    Cursor cursor{words.subspan(1)};
    while (const auto word = cursor.next()) {
      const std::string_view arg = *word;
      if (arg == "--json") {
        self.json = true;
        continue;
      }

      const auto value = cursor.take("MissingRepositoryOptionValue");
      if (arg == "--machine" && self.action == Action::prepare) {
        self.machine = value;
      } else if (arg == "--from" && self.action == Action::prepare) {
        self.from = value;
      } else if (arg == "--workspace") {
        self.workspace = value;
      } else if (arg == "--identity" && self.action != Action::prepare) {
        self.identity = value;
      } else if (arg == "--transport" && self.action == Action::receive) {
        self.transport = value;
      } else if (arg == "--commit" && self.action == Action::receive) {
        self.commit = value;
      } else if (arg == "--ref" && self.action == Action::receive) {
        self.ref = value;
      } else if (arg == "--bytes" && self.action == Action::receive) {
        self.bytes = parseUnsigned<std::uint64_t>(value);
      } else {
        throw std::invalid_argument{"UnknownRepositoryOption"};
      }
    }

    if (self.action == Action::prepare && !self.machine) {
      throw std::invalid_argument{"MissingMachineLabel"};
    }

    if (self.action == Action::tips && self.identity.empty()) {
      throw std::invalid_argument{"MissingRepositoryIdentity"};
    }

    return self;
  }
};

}
}

// Interface: repository_receive.cppm
export {
namespace telar::runtime::cli::repository {

struct PreparedRepository {
  std::string path;
  std::string commit;
  std::string repository;
  bool reused;

  inline std::string json(bool receiver = false) const {
    const auto prefix = std::format("{{\"path\":{},\"commit\":{},\"repository\":{},", quoteJson(path), quoteJson(commit), quoteJson(repository));
    return prefix + (receiver ? "\"repository_ready\":true,\"reused\":" + std::string{jsonBoolean(reused)} : "\"reused\":" + std::string{jsonBoolean(reused)} + ",\"repository_ready\":true") + ",\"environment\":\"not_run\"}\n";
  }
};

class StagingDirectory {
public:
  inline explicit StagingDirectory(std::string path)
      : path_(std::move(path)) {}

  inline ~StagingDirectory() {
    std::error_code ignored;
    std::filesystem::remove_all(path_, ignored);
  }

  StagingDirectory(const StagingDirectory &) = delete;
  StagingDirectory &operator=(const StagingDirectory &) = delete;

private:
  std::string path_;
};

inline bool validCommit(std::string_view commit) {
  constexpr std::size_t sha1_chars = 40;
  constexpr std::size_t sha256_chars = 64;
  return (commit.size() == sha1_chars || commit.size() == sha256_chars) && std::ranges::all_of(commit, [](unsigned char byte) {
           return (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f') || (byte >= 'A' && byte <= 'F');
         });
}

inline FileDescriptor lockRepository(int parent, const std::string &name) {
  const auto lock_name = name + ".lock";
  FileDescriptor file{::openat(parent, lock_name.c_str(), O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0600)};
  struct stat state{};
  if (!file || ::fstat(file.get(), &state) != 0 || !S_ISREG(state.st_mode) || state.st_uid != ::getuid() || state.st_nlink != 1 || (state.st_mode & 0077) != 0) {
    throw std::runtime_error{"UnsafeRepositoryLock"};
  }

  while (::flock(file.get(), LOCK_EX) != 0) {
    if (errno != EINTR) {
      throw std::runtime_error{file_transfer::fileError(errno)};
    }
  }

  return file;
}

template <Allocator Memory>
void clearPriorStage(Memory &memory, const std::string &stage, std::string_view identity) {
  struct stat state{};
  if (::lstat(stage.c_str(), &state) != 0) {
    if (errno == ENOENT) {
      return;
    }

    throw std::runtime_error{file_transfer::fileError(errno)};
  }

  if (!S_ISDIR(state.st_mode)) {
    throw std::runtime_error{"UnownedRepositoryStage"};
  }

  auto directory = file_transfer::openDirectory(stage);
  Vector<unsigned char, Memory> marker{AllocatorRef<unsigned char, Memory>{memory}};
  if (!readPrivateFile(directory.get(), "owner", marker, 2048) || std::string_view{reinterpret_cast<const char *>(marker.data()), marker.size()} != identity) {
    throw std::runtime_error{"UnownedRepositoryStage"};
  }

  std::filesystem::remove_all(stage);
}

inline void receiveBundle(int descriptor, std::uint64_t expected) {
  std::array<Byte, file_transfer::copy_buffer_bytes> bytes;
  std::uint64_t total = 0;
  for (;;) {
    const auto count = ::read(STDIN_FILENO, bytes.data(), bytes.size());
    if (count < 0 && errno == EINTR) {
      continue;
    }

    if (count < 0) {
      throw std::runtime_error{file_transfer::fileError(errno)};
    }

    if (count == 0) {
      break;
    }

    total += static_cast<std::uint64_t>(count);
    if (total > expected) {
      throw std::runtime_error{"RepositoryTransferLength"};
    }

    writeBytes(descriptor, std::span{bytes}.first(static_cast<std::size_t>(count)));
  }

  if (total != expected) {
    throw std::runtime_error{"RepositoryTransferInterrupted"};
  }
}

template <Allocator Memory>
PreparedRepository receive(Memory &memory, const RepositoryOptions &options) {
  if (normalize(options.transport) != options.identity || !validCommit(options.commit) || !options.ref.starts_with("refs/telar/transfer/") || options.bytes == 0 || options.bytes > max_bundle_bytes) {
    throw std::runtime_error{"InvalidRepositoryTransfer"};
  }

  const auto managed = managedPath(options.identity);
  const auto slash = managed.rfind('/');
  const auto base = managed.substr(slash + 1);
  auto parent = file_transfer::openDirectory(std::string_view{managed}.substr(0, slash), true);
  auto lock = lockRepository(parent.get(), base);
  const auto existing = find(memory, options.identity, options.workspace);
  const auto stage = managed + ".stage";
  clearPriorStage(memory, stage, options.identity);
  const auto stage_name = base + ".stage";
  if (::mkdirat(parent.get(), stage_name.c_str(), 0700) != 0) {
    throw std::runtime_error{file_transfer::fileError(errno)};
  }

  StagingDirectory cleanup{stage};
  auto directory = file_transfer::openDirectory(stage);
  FileDescriptor owner{::openat(directory.get(), "owner", O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600)};
  if (!owner) {
    throw std::runtime_error{file_transfer::fileError(errno)};
  }

  writeText(options.identity, owner.get());
  FileDescriptor bundle{::openat(directory.get(), "history.bundle", O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600)};
  if (!bundle) {
    throw std::runtime_error{file_transfer::fileError(errno)};
  }

  receiveBundle(bundle.get(), options.bytes);
  const auto bundle_path = stage + "/history.bundle";
  const auto staged_repository = stage + "/repository";
  const auto root = existing.value_or(staged_repository);
  if (!existing && ::mkdirat(directory.get(), "repository", 0700) != 0) {
    throw std::runtime_error{file_transfer::fileError(errno)};
  }

  Git git{memory, root};
  if (!existing) {
    git.read({"init", "--template="});
  }

  git.read({"bundle", "verify", bundle_path});
  git.read({"-c", "protocol.file.allow=always", "fetch", "--no-tags", "--", bundle_path, options.ref});
  if (git.read({"rev-parse", "--verify", "FETCH_HEAD^{commit}"}) != options.commit) {
    throw std::runtime_error{"RepositoryCommitMismatch"};
  }

  ready(git, options.commit);
  if (!existing) {
    git.read({"config", "remote.origin.url", options.transport});
    git.read({"checkout", "--detach", options.commit});
    const auto relative = stage_name + "/repository";
    try {
      file_transfer::publish(parent.get(), relative.c_str(), base.c_str());
    } catch (const std::runtime_error &error) {
      throw std::runtime_error{std::string_view{error.what()} == "PathAlreadyExists" ? "RepositoryDestinationOccupied" : "RepositoryPublicationFailed"};
    }
  }

  return {.path = existing.value_or(managed), .commit = std::string{options.commit}, .repository = std::string{options.identity}, .reused = existing.has_value()};
}

}
}

// Interface: repository_prepare.cppm
export {
namespace telar::runtime::cli::repository {

inline constexpr std::size_t max_transfer_tips = 256;

// The destination side of the history negotiation: the newest ref tips of
// the clone `receive` would update, one per line, or nothing without a clone.
template <Allocator Memory>
std::string tips(Memory &memory, const RepositoryOptions &options) {
  const auto found = find(memory, options.identity, options.workspace);
  if (!found) {
    return {};
  }

  Git git{memory, *found};
  auto listing = git.read({"for-each-ref", "--sort=-committerdate", std::format("--count={}", max_transfer_tips), "--format=%(objectname)"});
  if (!listing.empty()) {
    listing += '\n';
  }

  return listing;
}

inline void appendHashes(std::vector<std::string> &hashes, std::string_view listing) {
  for (const auto line : std::views::split(listing, '\n')) {
    const std::string_view hash{line.begin(), line.end()};
    if (hashes.size() < max_transfer_tips && validCommit(hash)) {
      hashes.emplace_back(hash);
    }
  }
}

// What the bundle leaves out: the machine's tips, which its clone holds with
// all their history. When they already reach `commit`, its parents instead,
// since Git refuses an empty bundle. Only hashes pass, never an option.
template <Allocator Memory>
std::vector<std::string> exclusions(Git<Memory> &git, std::string_view commit, std::string_view listing) {
  std::vector<std::string> tips;
  appendHashes(tips, listing);
  if (tips.empty()) {
    return tips;
  }

  std::vector<std::string_view> count{"rev-list", "--count", "--ignore-missing", commit, "--not"};
  count.insert(count.end(), tips.begin(), tips.end());
  if (git.read(count) != "0") {
    return tips;
  }

  std::vector<std::string> parents;
  appendHashes(parents, git.read({"rev-parse", std::string{commit} + "^@"}));
  return parents;
}

template <Allocator Memory>
PreparedRepository parsePrepared(Memory &memory, std::string_view output, std::string_view commit, std::string_view identity) {
  const auto result = JsonNode<Memory>::parse(memory, output);
  const auto *path = result.find("path");
  const auto *received_commit = result.find("commit");
  const auto *repository = result.find("repository");
  const auto *ready = result.find("repository_ready");
  const auto *reused = result.find("reused");
  if (path == nullptr || path->kind() != JsonKind::string || !path->text().starts_with('/') || path->text().contains('\0') || received_commit == nullptr || received_commit->text() != commit || repository == nullptr || repository->text() != identity || ready == nullptr || ready->text() != "true" || reused == nullptr || (reused->text() != "true" && reused->text() != "false")) {
    throw std::runtime_error{"InvalidPreparationResult"};
  }

  return {.path = std::string{path->text()}, .commit = std::string{commit}, .repository = std::string{identity}, .reused = reused->text() == "true"};
}

// Repository preparation: bundles `options.from`, less what the other
// machine's clone already holds, and has that machine's telar receive it.
// `capture` runs the given telar words there with the descriptor as stdin
// (-1 for none) and returns their stdout.
template <Allocator Memory, typename Capture>
PreparedRepository prepare(Memory &memory, const RepositoryOptions &options, std::string_view remote_program, Capture &&capture) {
  const auto cwd = std::filesystem::canonical(".").string();
  const auto root = mainRoot(memory, cwd);
  Git git{memory, root};
  std::string commit;
  try {
    commit = git.read({"rev-parse", "--verify", "--quiet", "--end-of-options", std::string{options.from} + "^{commit}"});
  } catch (const std::exception &) {
    throw std::runtime_error{"UnknownRevision"};
  }

  ready(git, commit);
  const auto origin = git.read({"config", "--get", "remote.origin.url"});
  const auto identity = normalize(origin);
  const auto transport = sanitized(origin);
  const auto status = git.read({"status", "--porcelain"});
  if (!status.empty()) {
    const auto dirty = static_cast<std::size_t>(std::count(status.begin(), status.end(), '\n')) + 1;
    writeText(std::format("telar repository: {} uncommitted files stay on this machine\n", dirty), STDERR_FILENO);
  }

  std::vector<std::string_view> query{"repository", "tips", "--identity", identity};
  if (options.workspace) {
    query.push_back("--workspace");
    query.push_back(*options.workspace);
  }

  // Without an answer the whole history travels, as to a new clone.
  std::string listing;
  try {
    listing = capture(std::span<const std::string_view>{query}, -1);
  } catch (const std::exception &) {
  }

  const auto excluded = exclusions(git, commit, listing);
  const ProcessEnvironment environment;
  const auto base = environment.lookup("TMPDIR");
  const auto temporary = std::format("{}/telar-transfer-{:016x}{:016x}", base.empty() ? "/tmp" : base, randomIdentity(), randomIdentity());
  if (::mkdir(temporary.c_str(), 0700) != 0) {
    throw std::runtime_error{file_transfer::fileError(errno)};
  }

  StagingDirectory cleanup{temporary};
  // TMPDIR may sit behind a symlink (macOS's /var); only the directory just
  // created, private to this process, must not be one.
  FileDescriptor directory{::open(temporary.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
  if (!directory) {
    throw std::runtime_error{file_transfer::fileError(errno)};
  }

  FileDescriptor bundle{::openat(directory.get(), "history.bundle", O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0600)};
  if (!bundle) {
    throw std::runtime_error{file_transfer::fileError(errno)};
  }

  const auto ref = "refs/telar/transfer/" + std::filesystem::path{temporary}.filename().string();
  git.read({"update-ref", ref, commit, ""});
  const auto delete_ref = [&] {
    try {
      git.read({"update-ref", "-d", ref, commit});
    } catch (const std::exception &) {
    }
  };
  try {
    std::vector<std::string_view> revisions{ref};
    if (!excluded.empty()) {
      revisions.insert(revisions.end(), {"--ignore-missing", "--not"});
      revisions.insert(revisions.end(), excluded.begin(), excluded.end());
    }

    git.bundle(revisions, bundle.get());
    struct stat inode{};
    if (::fstat(bundle.get(), &inode) != 0) {
      throw std::runtime_error{file_transfer::fileError(errno)};
    }

    if (::lseek(bundle.get(), 0, SEEK_SET) != 0) {
      throw std::runtime_error{file_transfer::fileError(errno)};
    }

    const auto size = std::to_string(inode.st_size);
    std::vector<std::string_view> words{"exec", "--", remote_program, "repository", "receive", "--identity", identity, "--transport", transport, "--commit", commit, "--ref", ref, "--bytes", size};
    if (options.workspace) {
      words.push_back("--workspace");
      words.push_back(*options.workspace);
    }

    const auto output = capture(std::span<const std::string_view>{words}, bundle.get());
    auto result = parsePrepared(memory, output, commit, identity);
    delete_ref();
    return result;
  } catch (...) {
    delete_ref();
    throw;
  }
}

// Shared by `repository prepare` and `worktree create --machine`.
template <Allocator Memory>
PreparedRepository prepare(Memory &memory, const RepositoryOptions &options, const machines::MachineProfile &profile) {
  return prepare(memory, options, profile.program().value_or("telar"), [&](std::span<const std::string_view> words, int input) { return machine::capture(memory, profile, words, "RepositoryTransferFailed", input); });
}

template <Allocator Memory>
int run(Memory &memory, const RepositoryOptions &options) {
  try {
    if (options.action == RepositoryOptions::Action::receive) {
      writeText(receive(memory, options).json(true));
    } else if (options.action == RepositoryOptions::Action::tips) {
      writeText(tips(memory, options));
    } else {
      const auto profile = machine::resolve(memory, *options.machine);
      if (!profile) {
        throw std::runtime_error{"PreparationNeedsAnotherMachine"};
      }

      writeText(prepare(memory, options, *profile).json());
    }

    return 0;
  } catch (const std::exception &error) {
    writeText("telar repository: " + std::string{error.what()} + "\n", STDERR_FILENO);
    return 1;
  }
}

}
}

// Interface: worktree_dispatch.cppm
export {
// Worktrees on another machine, from the machine that dispatches them:
// `create --machine` finds the project's clone
// there, pushes the commit the branch starts from and asks that machine's
// telar to create the worktree; `fetch --machine` brings the branch back into
// a remote-tracking ref. All Git traffic starts here over telar's managed SSH
// connection, so no machine ever needs SSH back to this one.
namespace telar::runtime::cli::sessions {

enum class GitDirection : std::uint8_t {
  push,
  fetch
};

// Descriptions of the errors only dispatch raises.
inline std::string_view describeDispatchError(std::string_view name) {
  static constexpr std::array<std::pair<std::string_view, std::string_view>, 12> descriptions{{
      {"UnknownMachine", "no saved machine or local label has that name; see `telar machine list`"},
      {"FetchNeedsAnotherMachine", "fetch brings a branch from another machine; this label names this one"},
      {"NoOriginRemote", "the repository has no `origin` remote to find its clone by on the other machine"},
      {"UnsupportedOrigin", "the `origin` remote is a local path, which names no clone on another machine"},
      {"UnexpectedResolveOutput", "the machine answered `worktree resolve` with something else; is its telar up to date?"},
      {"MachineCommandFailed", "the command failed on the machine"},
      {"UnknownRevision", "that revision names no commit here"},
      {"GitPushFailed", "git push to the machine failed; a branch with other history there is never overwritten"},
      {"GitFetchFailed", "git fetch from the machine failed"},
      {"DestinationNotUsableByGit", "the machine's SSH destination has ':', '/' or brackets; save it as a host alias"},
      {"UnquotableSshOption", "telar's runtime directory has a quote in its path, which git cannot be given safely"},
      {"NotARepository", "not inside a git repository"},
  }};
  const auto found = std::ranges::find(descriptions, name, &std::pair<std::string_view, std::string_view>::first);
  return found == descriptions.end() ? name : found->second;
}

template <Allocator Memory>
class WorktreeDispatch {
public:
  inline WorktreeDispatch(Memory &memory, const WorktreeOptions &options, const machines::MachineProfile &profile)
      : memory_(memory),
        options_(options),
        profile_(profile),
        git_(memory),
        root_(git_.root(std::filesystem::canonical(".").string())) {}

  inline int create() {
    const auto branch = *options_.branch;
    const bool continued = git_.succeeds({"git", "-C", root_, "rev-parse", "--verify", "--quiet", "refs/heads/" + std::string{branch}});
    const auto source = continued ? branch : options_.from.value_or("HEAD");
    const auto commit = commitOf(source);
    const RepositoryOptions prepare_options{
        .action = RepositoryOptions::Action::prepare,
        .from = commit,
        .workspace = options_.workspace,
    };
    const auto clone = repository::prepare(memory_, prepare_options, profile_).path;
    transfer(clone, commit + ":refs/heads/" + std::string{branch}, GitDirection::push);
    const auto profiles = machine::load(memory_, machine::profilesPath());
    const auto local = machine::localLabel(profiles).substr(0, machines::MachineLimits::label_bytes);
    const auto coordinator = options_.coordinator ? options_.coordinator : sourceCoordinator();
    std::vector<std::string> words{"worktree", "create", std::string{branch}, "--workspace", clone, "--dispatched-from", std::string{local}};
    const auto optional = [&](std::string_view flag, std::optional<std::string> value) {
      if (value) {
        words.emplace_back(flag);
        words.push_back(std::move(*value));
      }
    };
    optional("--title", options_.title ? std::optional<std::string>{*options_.title} : std::nullopt);
    optional("--label", options_.label ? std::optional<std::string>{*options_.label} : std::nullopt);
    optional("--coordinator", coordinator ? std::optional{formatCoordinator(*coordinator)} : std::nullopt);
    optional("--from", continued ? std::nullopt : std::optional{commit});
    if (options_.setup) {
      words.emplace_back("--setup");
    }

    if (options_.json) {
      words.emplace_back("--json");
    }

    if (!options_.command.empty()) {
      words.emplace_back("--");
      words.insert(words.end(), options_.command.begin(), options_.command.end());
    }

    return machine::forward(memory_, profile_, words);
  }

  inline int fetch() {
    const auto branch = *options_.branch;
    const auto label = *options_.machine;
    const auto clone = findClone();
    const auto ref = std::format("refs/remotes/{}/{}", label, branch);
    transfer(clone, std::format("+refs/heads/{}:{}", branch, ref), GitDirection::fetch);
    const auto commit = commitOf(ref);
    Output output{memory_};
    if (options_.json) {
      output.text("{\"machine\":").json(label).text(",\"branch\":").json(branch).text(",\"ref\":").json(ref).text(",\"commit\":").json(commit).text("}\n");
    } else {
      output.text(std::format("fetched {} from {} into {} at {}\n", branch, label, ref, commit));
    }

    output.flush();
    return 0;
  }

private:
  inline std::string commitOf(std::string_view revision) {
    try {
      return git_.line({"git", "-C", root_, "rev-parse", "--verify", "--quiet", "--end-of-options", std::string{revision} + "^{commit}"});
    } catch (const std::exception &) {
      throw Failure{"UnknownRevision"};
    }
  }

  inline std::string originIdentity() {
    std::string url;
    try {
      url = git_.line({"git", "-C", root_, "config", "--get", "remote.origin.url"});
    } catch (const std::exception &) {
      throw Failure{"NoOriginRemote"};
    }

    return repository::normalize(url);
  }

  // Asks the other machine which of its workspaces holds this repository.
  inline std::string findClone() {
    const std::vector<std::string> words{"worktree", "resolve", "--repository", originIdentity(), "--json"};
    const auto output = machine::capture(memory_, profile_, words, "MachineCommandFailed");
    try {
      const auto resolved = JsonNode<Memory>::parse(memory_, output);
      const auto *path = resolved.find("path");
      if (path != nullptr && path->kind() == JsonKind::string && path->text().starts_with('/')) {
        return std::string{path->text()};
      }
    } catch (const std::exception &) {
    }

    throw Failure{"UnexpectedResolveOutput"};
  }

  // One push or fetch against the other machine's clone, through the control
  // master the dispatch uses. A push never forces.
  inline void transfer(std::string_view clone, std::string_view refspec, GitDirection direction) {
    const auto destination = profile_.destination();
    if (destination.find_first_of(":/[]") != std::string_view::npos) {
      throw Failure{"DestinationNotUsableByGit"};
    }

    const auto url = std::format("ssh://{}{}", destination, clone);
    const auto ssh = machine::gitSshCommand(memory_, destination);
    const std::array<std::pair<std::string_view, std::string_view>, 2> environment{{{"GIT_SSH_COMMAND", ssh}, {"GIT_TERMINAL_PROMPT", "0"}}};
    if (direction == GitDirection::push) {
      const std::array<std::string_view, 8> argv{"git", "-C", root_, "push", "--quiet", "--", url, refspec};
      git_.run(argv, "GitPushFailed", true, false, environment);
    } else {
      const std::array<std::string_view, 9> argv{"git", "-C", root_, "fetch", "--quiet", "--no-tags", "--", url, refspec};
      git_.run(argv, "GitFetchFailed", true, false, environment);
    }
  }

  // The agent session of the pane this command runs in, when the runtime
  // confirms the process descends from it.
  inline std::optional<CoordinatorReference> sourceCoordinator() {
    const auto id = maybeUnsigned(process_environment.lookup("TELAR_PANE_ID"));
    const auto generation = maybeUnsigned(process_environment.lookup("TELAR_PANE_GENERATION"));
    if (!id || !generation || *id == 0 || *generation == 0) {
      return std::nullopt;
    }

    try {
      Channel<Memory> session{memory_, std::nullopt, false};
      session.template exchange<RequestCompleted>(VerifyPaneDescent{.pane_id = *id, .pane_generation = *generation});
      const auto agents = session.template exchange<AgentSnapshot>(QueryAgents{});
      for (const auto &entry : agents.entries) {
        if (entry.pane_id == *id && entry.pane_generation == *generation && std::ranges::any_of(entry.session_id, [](Byte byte) { return byte != 0; })) {
          return CoordinatorReference{.session_id = entry.session_id, .pane_id = *id, .pane_generation = *generation};
        }
      }
    } catch (const std::exception &) {
    }

    return std::nullopt;
  }

  inline static std::string formatCoordinator(const CoordinatorReference &reference) {
    std::string text;
    for (const auto byte : reference.session_id) {
      text += std::format("{:02x}", static_cast<unsigned>(byte));
    }

    return std::format("{}:{}:{}", text, reference.pane_id, reference.pane_generation);
  }

  Memory &memory_;
  const WorktreeOptions &options_;
  const machines::MachineProfile &profile_;
  WorktreeGit<Memory> git_;
  std::string root_;
};

}
}

// Interface: worktree_output.cppm
export {
namespace telar::runtime::cli::sessions {

inline std::string hexSession(const std::array<Byte, 16> &session) {
  constexpr std::string_view digits = "0123456789abcdef";
  std::string result;
  for (const auto byte : session) {
    result += digits[byte >> 4];
    result += digits[byte & 15];
  }
  return result;
}

inline std::string_view agentStatus(AgentStatus status) {
  switch (status) {
  case AgentStatus::unknown:
    return "unknown";
  case AgentStatus::working:
    return "working";
  case AgentStatus::blocked:
    return "blocked";
  case AgentStatus::ready:
    return "ready";
  case AgentStatus::done:
    return "done";
  case AgentStatus::failed:
    return "failed";
  }
  return "unknown";
}

inline std::string_view blockedReason(AgentBlockedReason reason) {
  switch (reason) {
  case AgentBlockedReason::none:
    return "none";
  case AgentBlockedReason::permission:
    return "permission";
  case AgentBlockedReason::question:
    return "question";
  case AgentBlockedReason::plan:
    return "plan";
  case AgentBlockedReason::other:
    return "other";
  }
  return "none";
}

template <Allocator Memory>
void worktreeAgent(Output<Memory> &output, const AgentSnapshotEntry &agent) {
  constexpr auto escapes = JsonEscapes::control;
  output.text("{\"pane_id\":").number(agent.pane_id).text(",\"pane_generation\":").number(agent.pane_generation).text(",\"workspace_id\":").number(agent.location.workspace.id).text(",\"tab_id\":").number(agent.location.tab_id).text(",\"pane_index\":").number(agent.pane_index).text(",\"provider\":").json(agent.provider_name.empty() ? "unknown" : agent.provider_name, escapes).text(",\"provider_index\":").number(static_cast<Byte>(agent.provider)).text(",\"status\":").json(agentStatus(agent.status), escapes).text(",\"workspace\":").json(agent.workspace_label, escapes).text(",\"tab\":").json(agent.tab_label, escapes).text(",\"title\":").json(agent.session_title, escapes).text(",\"cwd\":").json(agent.cwd_label, escapes).text(",\"blocked_reason\":").json(blockedReason(agent.blocked_reason), escapes).text(",\"status_age_s\":").number(agent.status_age_s).text(",\"worktree_id\":").number(agent.work_tree).text(",\"last_event\":").json(agent.last_event, escapes).text(",\"plan\":{\"done\":").number(agent.plan_done).text(",\"total\":").number(agent.plan_total).text(",\"step\":").json(agent.plan_step, escapes).text("},\"final_message\":").json(agent.final_message, escapes).text(",\"session_id\":").json(hexSession(agent.session_id), escapes).text("}");
}

inline std::string_view worktreeState(WorktreeState state) {
  switch (state) {
  case WorktreeState::active:
    return "active";
  case WorktreeState::integrated:
    return "integrated";
  case WorktreeState::gone:
    return "gone";
  }
  return "active";
}

inline std::string_view commandState(CommandState state) {
  switch (state) {
  case CommandState::none:
    return "none";
  case CommandState::running:
    return "running";
  case CommandState::exited:
    return "exited";
  }
  return "none";
}

template <Allocator Memory>
void worktreeEntry(Output<Memory> &output, const WorktreeListEntry &entry, std::span<const AgentSnapshotEntry> agents, bool json) {
  constexpr auto escapes = JsonEscapes::control;
  if (!json) {
    const auto member = std::ranges::find(agents, entry.worktree, &AgentSnapshotEntry::work_tree);
    output.text(entry.branch).text("\t").text(entry.title.empty() ? entry.branch : entry.title).text("\t").text(worktreeState(entry.state)).text("\t").text(member == agents.end() ? "-" : agentStatus(member->status)).text("\t+").number(entry.diff_added).text(" -").number(entry.diff_removed).text(" ").number(entry.diff_files).text(" files\t").text(entry.command_label.empty() ? "-" : entry.command_label).text(" ").text(commandState(entry.command_state)).text("\t").text(entry.path).text("\n");
    return;
  }

  output.text("{\"worktree_id\":").number(entry.worktree).text(",\"branch\":").json(entry.branch, escapes).text(",\"title\":").json(entry.title, escapes).text(",\"brief\":").json(entry.brief, escapes).text(",\"base\":").json(entry.base, escapes).text(",\"dispatched_from\":").json(entry.dispatched_from, escapes).text(",\"coordinator\":");
  if (entry.coordinator) {
    output.text("{\"session_id\":").json(hexSession(entry.coordinator->session_id)).text(",\"pane_id\":").number(entry.coordinator->pane_id).text(",\"pane_generation\":").number(entry.coordinator->pane_generation).text("}");
  } else {
    output.text("null");
  }
  output.text(",\"path\":").json(entry.path, escapes).text(",\"origin\":").json(entry.origin == WorktreeOrigin::telar ? "telar" : "external").text(",\"state\":").json(worktreeState(entry.state)).text(",\"source_workspace_id\":").number(entry.source).text(",\"workspace_id\":");
  if (entry.workspace) {
    output.number(*entry.workspace);
  } else {
    output.text("null");
  }
  output.text(",\"diff\":{\"added\":").number(entry.diff_added).text(",\"removed\":").number(entry.diff_removed).text(",\"files\":").number(entry.diff_files).text(",\"commits_ahead\":").number(entry.commits_ahead).text("},\"command\":{\"label\":").json(entry.command_label, escapes).text(",\"state\":").json(commandState(entry.command_state)).text(",\"exit_code\":").number(entry.command_exit).text("},\"agents\":[");
  bool first = true;
  for (const auto &agent : agents) {
    if (agent.work_tree != entry.worktree) {
      continue;
    }
    if (!first) {
      output.text(",");
    }
    worktreeAgent(output, agent);
    first = false;
  }
  output.text("]}");
}

struct WorktreeLaunch {
  std::optional<std::uint64_t> setup{};
  std::uint64_t worktree{};
  std::string_view path{}, branch{}, base{};
  PaneOpened opened{};
};

template <Allocator Memory>
void worktreeLaunch(Output<Memory> &output, const WorktreeLaunch &launch, bool json) {
  if (json) {
    output.text("{\"worktree_id\":").number(launch.worktree).text(",\"setup_execution_id\":");
    if (launch.setup) {
      output.number(*launch.setup);
    } else {
      output.text("null");
    }
    output.text(",\"environment\":").json(launch.setup ? "ready" : "not_declared").text(",\"branch\":").json(launch.branch).text(",\"base\":").json(launch.base).text(",\"path\":").json(launch.path).text(",\"workspace_id\":").number(launch.opened.location.workspace.id).text(",\"tab_id\":").number(launch.opened.location.tab_id).text(",\"pane_id\":").number(launch.opened.pane_id).text(",\"pane_generation\":").number(launch.opened.pane_generation).text("}\n");
  } else {
    output.text("worktree ").text(launch.branch).text(" at ").text(launch.path).text(": pane ").number(launch.opened.pane_id).text(" in workspace ").number(launch.opened.location.workspace.id).text("\n");
  }
}

}
}

// Interface: worktree_setup.cppm
export {
namespace telar::runtime::cli::sessions {

template <Allocator Memory>
void recipeVersion(Memory &memory, JsonValue version) {
  String<Memory> decoded{AllocatorRef<char, Memory>{memory}};
  auto encoded = version.encoded();
  if (encoded.starts_with('"')) {
    version.string(decoded);
    encoded = decoded;
  } else if (encoded.empty() || (encoded.front() != '-' && (encoded.front() < '0' || encoded.front() > '9'))) {
    throw Failure{"UnexpectedToken"};
  }
  if (encoded.empty() || encoded.front() == '_' || encoded.back() == '_' || encoded.find_first_of(" \t\r\n") != std::string_view::npos) {
    throw Failure{"InvalidCharacter"};
  }
  std::string number;
  for (const auto byte : encoded) {
    if (byte != '_') {
      number += byte;
    }
  }
  char *end{};
  const auto value = std::strtold(number.c_str(), &end);
  if (end != number.data() + number.size()) {
    throw Failure{"InvalidCharacter"};
  }
  if (!std::isfinite(value) || std::round(value) != value) {
    throw Failure{"InvalidNumber"};
  }
  if (value < 0 || value > std::numeric_limits<std::uint8_t>::max()) {
    throw Failure{"Overflow"};
  }
  if (value != 1) {
    throw Failure{"InvalidProjectRecipe"};
  }
}

inline FileDescriptor setupDirectory(std::string_view cwd) {
  if (!cwd.starts_with('/')) {
    throw Failure{"AbsoluteFilePathRequired"};
  }
  std::string path{cwd};
  path += "/.telar";
  FileDescriptor current{::open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
  if (!current) {
    throw Failure{"AccessDenied"};
  }
  std::string_view remaining = path;
  while (!remaining.empty()) {
    const auto slash = remaining.find('/');
    const auto component = remaining.substr(0, slash);
    remaining.remove_prefix(slash == std::string_view::npos ? remaining.size() : slash + 1);
    if (component.empty()) {
      continue;
    }
    if (component == "." || component == "..") {
      throw Failure{"InvalidFilePath"};
    }
    const std::string name{component};
    FileDescriptor next{::openat(current.get(), name.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
    if (!next) {
      if (errno == ENOENT) {
        return FileDescriptor{};
      }
      if (errno == ENOTDIR) {
        throw Failure{"NotDir"};
      }
      if (errno == ELOOP) {
        throw Failure{"SymLinkLoop"};
      }
      throw Failure{"AccessDenied"};
    }
    current = std::move(next);
  }
  struct stat status{};
  if (::fstat(current.get(), &status) != 0 || status.st_uid != ::getuid() || (status.st_mode & 0022) != 0) {
    throw Failure{"UnsafeTransferDirectory"};
  }
  return current;
}

// Open every component without following symlinks. A recipe from a checkout is
// executable input and requires the explicit setup flag before it is parsed.
template <Allocator Memory>
std::optional<std::uint64_t> worktreeSetup(Memory &memory, Channel<Memory> &session, const std::string &cwd, bool authorized) {
  constexpr std::size_t recipe_bytes = 32 * 1024;
  constexpr std::size_t max_arguments = 64;
  auto parent = setupDirectory(cwd);
  if (!parent) {
    return std::nullopt;
  }

  FileDescriptor file{::openat(parent.get(), "setup.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)};
  if (file.get() < 0) {
    if (errno == ENOENT) {
      return std::nullopt;
    }
    throw Failure{"UnsafeTransferFile"};
  }

  struct stat status{};
  if (::fstat(file.get(), &status) != 0 || !S_ISREG(status.st_mode) || status.st_uid != ::getuid() || status.st_nlink != 1) {
    throw Failure{"UnsafeTransferFile"};
  }
  if (!authorized) {
    throw Failure{"ProjectSetupRequiresExplicitSetupFlag"};
  }
  if (status.st_size > static_cast<off_t>(recipe_bytes)) {
    throw Failure{"InvalidProjectRecipe"};
  }

  std::string bytes;
  std::array<char, recipe_bytes + 1> buffer;
  for (;;) {
    const auto count = ::read(file.get(), buffer.data(), buffer.size());
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count < 0) {
      throw Failure{"InvalidProjectRecipe"};
    }
    if (count == 0) {
      break;
    }
    if (static_cast<std::size_t>(count) > recipe_bytes - bytes.size()) {
      throw Failure{"InvalidProjectRecipe"};
    }
    bytes.append(buffer.data(), static_cast<std::size_t>(count));
  }

  Vector<String<Memory>, Memory> arguments{AllocatorRef<String<Memory>, Memory>{memory}};
  try {
    const auto recipe = JsonValue::parse(bytes);
    if (!recipe.encoded().starts_with('{')) {
      throw Failure{"UnexpectedToken"};
    }
    std::optional<JsonValue> version, argv;
    recipe.eachMember([&](JsonValue key, JsonValue value) {
      String<Memory> name{AllocatorRef<char, Memory>{memory}};
      key.string(name);
      if (name == "version") {
        if (version) {
          throw Failure{"DuplicateField"};
        }
        version = value;
      } else if (name == "argv") {
        if (argv) {
          throw Failure{"DuplicateField"};
        }
        argv = value;
      } else {
        throw Failure{"UnknownField"};
      }
    });
    if (!version || !argv) {
      throw Failure{"MissingField"};
    }
    recipeVersion(memory, *version);
    if (!argv->encoded().starts_with('[')) {
      throw Failure{"UnexpectedToken"};
    }
    argv->eachElement([&](JsonValue value) {
      if (arguments.size() == max_arguments) {
        throw Failure{"InvalidProjectRecipe"};
      }
      String<Memory> argument{AllocatorRef<char, Memory>{memory}};
      if (!value.encoded().starts_with('"')) {
        throw Failure{"UnexpectedToken"};
      }
      value.string(argument);
      arguments.push_back(std::move(argument));
    });
    if (arguments.empty()) {
      throw Failure{"InvalidProjectRecipe"};
    }
  } catch (const Failure &) {
    throw;
  } catch (const std::exception &) {
    throw Failure{"SyntaxError"};
  }

  std::array<std::string_view, max_arguments> argv;
  for (std::size_t index = 0; index < arguments.size(); ++index) {
    argv[index] = arguments[index];
  }
  std::uint64_t id{};
  while (id == 0) {
    randomBytes(&id, sizeof(id));
  }
  ExecutionRequest request{.action = ExecutionAction::start, .execution_id = id, .cwd = cwd, .arguments = std::span{argv}.first(arguments.size())};
  std::fprintf(stderr, "telar project: setup execution %llu; each explicit invocation repeats the recipe\n", static_cast<unsigned long long>(id));
  auto reply = session.template exchange<ExecutionReply>(request);
  request.action = ExecutionAction::status;
  request.arguments = {};
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{default_wait_seconds};
  for (;;) {
    if (request.stdout_offset != reply.stdout_offset || request.stderr_offset != reply.stderr_offset) {
      throw Failure{"SetupOutputRetentionExceeded"};
    }
    std::fwrite(reply.stdout_bytes.data(), 1, reply.stdout_bytes.size(), stderr);
    std::fwrite(reply.stderr_bytes.data(), 1, reply.stderr_bytes.size(), stderr);
    request.stdout_offset += reply.stdout_bytes.size();
    request.stderr_offset += reply.stderr_bytes.size();
    if ((reply.state == ExecutionState::exited || reply.state == ExecutionState::failed) && request.stdout_offset == reply.stdout_total && request.stderr_offset == reply.stderr_total) {
      if (reply.state != ExecutionState::exited || reply.exit_code != 0) {
        throw Failure{"ProjectSetupFailed"};
      }
      return id;
    }

    if (std::chrono::steady_clock::now() >= deadline) {
      throw Failure{"SetupWaitTimedOutExecutionContinues"};
    }
    std::this_thread::sleep_for(std::chrono::milliseconds{10});
    reply = session.template exchange<ExecutionReply>(request);
  }
}

}
}

// Interface: worktree.cppm
export {
namespace telar::runtime::cli::sessions {

inline std::optional<std::uint64_t> currentWorkspace() {
  const auto value = ::getenv("TELAR_WORKSPACE_ID");
  return value ? maybeUnsigned(value) : std::nullopt;
}

inline bool confirmRemoval(const char *question) {
  if (!::isatty(STDIN_FILENO)) {
    throw Failure{"this removal needs a person to confirm it at a terminal"};
  }
  std::fprintf(stderr, "%s? [y/N] ", question);
  std::array<char, 16> buffer;
  if (!std::fgets(buffer.data(), buffer.size(), stdin)) {
    return false;
  }
  std::string answer{buffer.data()};
  const auto begin = answer.find_first_not_of(" \r\t\n"), end = answer.find_last_not_of(" \r\t\n");
  if (begin == std::string::npos) {
    return false;
  }
  answer = answer.substr(begin, end - begin + 1);
  for (auto &byte : answer) {
    if (byte >= 'A' && byte <= 'Z') {
      byte += 'a' - 'A';
    }
  }
  return answer == "y" || answer == "yes";
}

template <Allocator Memory>
class WorktreeCommand {
public:
  inline WorktreeCommand(Memory &memory, const WorktreeOptions &options)
      : memory_(memory),
        options_(options),
        catalog_channel_(memory, options.socket, true),
        catalog_(catalog_channel_.catalog()),
        session_(memory, options.socket, false),
        git_(memory),
        output_(memory) {}

  WorktreeCommand(const WorktreeCommand &) = delete;
  WorktreeCommand &operator=(const WorktreeCommand &) = delete;

  inline int run() {
    using Action = WorktreeOptions::Action;
    int result = 0;
    switch (options_.action) {
    case Action::create:
      create();
      break;
    case Action::exec:
      result = exec();
      break;
    case Action::list:
      list();
      break;
    case Action::open:
      open();
      break;
    case Action::diff:
      diff();
      break;
    case Action::remove:
      remove();
      break;
    case Action::resolve:
      resolve();
      break;
    case Action::fetch:
      throw Failure{"fetch needs another machine"};
    }

    output_.flush();
    return result;
  }

private:
  inline const WorkspaceListEntry *workspace(std::uint64_t id) const {
    const auto found = std::ranges::find(catalog_.entries, id, &WorkspaceListEntry::workspace);
    return found == catalog_.entries.end() ? nullptr : &*found;
  }

  inline const WorkspaceListEntry *workspaceAt(std::string_view path) const {
    for (const auto &entry : catalog_.entries) {
      const bool holds_worktree = std::ranges::any_of(catalog_.worktrees, [&](const auto &worktree) { return worktree.workspace == entry.workspace; });
      if (entry.path == path && !holds_worktree) {
        return &entry;
      }
    }
    return nullptr;
  }

  inline const WorktreeListEntry *find(std::string_view reference) const {
    const WorktreeListEntry *found = nullptr;
    for (const auto &entry : catalog_.worktrees) {
      if (entry.branch != reference) {
        continue;
      }
      if (found) {
        throw Failure{"more than one worktree has that branch or title; name it by the other"};
      }
      found = &entry;
    }
    if (found) {
      return found;
    }

    const auto lower = [](unsigned char byte) { return byte >= 'A' && byte <= 'Z' ? byte + ('a' - 'A') : byte; };
    for (const auto &entry : catalog_.worktrees) {
      if (entry.title.size() != reference.size() || !std::equal(entry.title.begin(), entry.title.end(), reference.begin(), [&](auto left, auto right) { return lower(left) == lower(right); })) {
        continue;
      }
      if (found) {
        throw Failure{"more than one worktree has that branch or title; name it by the other"};
      }
      found = &entry;
    }
    return found;
  }

  inline std::string originDirectory() {
    if (options_.workspace) {
      if (const auto id = maybeUnsigned(*options_.workspace)) {
        const auto entry = workspace(*id);
        if (!entry) {
          throw Failure{"workspace not found", 2};
        }
        return std::string{entry->path};
      }
      return realDirectory(*options_.workspace);
    }

    if (const auto id = currentWorkspace()) {
      if (const auto entry = workspace(*id)) {
        return std::string{entry->path};
      }
    }
    return realDirectory(".");
  }

  inline std::uint64_t sourceWorkspace(std::string_view root) {
    if (options_.workspace) {
      if (const auto id = maybeUnsigned(*options_.workspace)) {
        return *id;
      }
    }
    if (const auto id = currentWorkspace()) {
      if (const auto entry = workspace(*id)) {
        try {
          if (git_.root(entry->path) == root) {
            return *id;
          }
        } catch (const std::exception &) {
        }
      }
    }
    if (const auto entry = workspaceAt(root)) {
      return entry->workspace;
    }

    const auto name = std::filesystem::path{root}.filename().string();
    const std::array shell{loginShell()};
    const auto opened = session_.template exchange<PaneOpened>(CreateWorkspace{.size = workspace_size, .name = name, .launch = {.cwd = root, .arguments = shell}});
    return opened.location.workspace.id;
  }

  inline std::optional<std::uint64_t> attributedPane() {
    // Each value is parsed before the next getenv, which may overwrite the storage it returned.
    const auto *id_text = ::getenv("TELAR_PANE_ID");
    const auto id = id_text ? maybeUnsigned(id_text) : std::nullopt;
    const auto *generation_text = ::getenv("TELAR_PANE_GENERATION");
    const auto generation = generation_text ? maybeUnsigned(generation_text) : std::nullopt;
    if (!id || !generation || *id == 0 || *generation == 0) {
      return std::nullopt;
    }
    try {
      session_.template exchange<RequestCompleted>(VerifyPaneDescent{.pane_id = *id, .pane_generation = *generation});
      verified_generation_ = *generation;
      return id;
    } catch (const std::exception &) {
      return std::nullopt;
    }
  }

  inline std::optional<CoordinatorReference> coordinator(std::optional<std::uint64_t> pane) {
    if (options_.coordinator) {
      return options_.coordinator;
    }
    if (!pane) {
      return std::nullopt;
    }
    const auto agents = session_.template exchange<AgentSnapshot>(QueryAgents{});
    for (const auto &entry : agents.entries) {
      if (entry.pane_id == *pane && entry.pane_generation == verified_generation_ && std::ranges::any_of(entry.session_id, [](Byte byte) { return byte != 0; })) {
        return CoordinatorReference{.session_id = entry.session_id, .pane_id = *pane, .pane_generation = verified_generation_};
      }
    }
    return std::nullopt;
  }

  inline std::string brief() const {
    std::string result;
    for (std::size_t index = 1; index < options_.command.size(); ++index) {
      if (index != 1 && result.size() < brief_bytes) {
        result += ' ';
      }
      for (const unsigned char byte : std::string_view{options_.command[index]}) {
        if (result.size() == brief_bytes) {
          break;
        }
        if ((byte >= ' ' && byte != 0x7f) || byte == '\n' || byte == '\t') {
          result += static_cast<char>(byte);
        }
      }
    }
    while (!result.empty()) {
      try {
        validateUtf8(result);
        break;
      } catch (const EncodingError &) {
        result.pop_back();
      }
    }
    return result;
  }

  inline PaneOpened launch(std::uint64_t id, std::string_view directory) {
    std::vector<std::string_view> argv;
    const auto shell = loginShell();
    if (options_.command.empty()) {
      argv.push_back(shell);
    } else {
      const auto name = std::filesystem::path{shell}.filename().string();
      std::string_view line;
      if (name == "bash" || name == "zsh" || name == "ksh") {
        line = "exec -- \"$0\" \"$@\"";
      } else if (name == "sh" || name == "dash") {
        line = "exec \"$0\" \"$@\"";
      } else if (name == "fish") {
        line = "exec $argv";
      }
      if (!line.empty()) {
        argv = {shell, "-l", "-i", "-c", line};
      }
      for (const auto word : options_.command) {
        argv.push_back(word);
      }
    }
    return session_.template exchange<PaneOpened>(LaunchWorktree{.worktree = id, .label = options_.label.value_or(""), .size = launch_size, .launch = {.cwd = directory, .arguments = argv}});
  }

  inline void create() {
    const auto directory = originDirectory();
    const auto root = git_.root(directory);
    const auto branch = *options_.branch;
    auto suffix = std::string{branch};
    std::replace(suffix.begin(), suffix.end(), '/', '-');
    std::replace(suffix.begin(), suffix.end(), '\\', '-');
    const auto checkout = options_.directory ? std::string{*options_.directory} : root + "-worktrees/" + suffix;
    for (const auto &entry : catalog_.worktrees) {
      if (entry.path == checkout || entry.branch == branch) {
        throw Failure{"that worktree already exists; use `telar worktree exec` to run more there"};
      }
    }
    const auto base = options_.from ? std::string{*options_.from} : git_.currentBranch(root);
    try {
      sessions::branch(base);
    } catch (const std::invalid_argument &) {
      throw Failure{"UnusableBase"};
    }
    constexpr std::size_t maximum_worktrees = 64;
    if (catalog_.worktrees.size() >= maximum_worktrees) {
      throw Failure{"WorktreeLimitReached"};
    }
    const auto source = sourceWorkspace(root);
    git_.add(root, checkout, branch, base);
    const auto pane = attributedPane();
    const auto reference = coordinator(pane);
    const auto description = brief();
    const auto registered = session_.template exchange<WorktreeRegistered>(RegisterWorktree{.source = source, .created_by = pane, .path = checkout, .branch = branch, .base = base, .title = options_.title.value_or(""), .brief = description, .dispatched_from = options_.dispatched_from.value_or(""), .coordinator = reference});
    const auto setup = worktreeSetup(memory_, session_, checkout, options_.setup);
    const auto opened = launch(registered.worktree, checkout);
    worktreeLaunch(output_, WorktreeLaunch{.setup = setup, .worktree = registered.worktree, .path = checkout, .branch = branch, .base = base, .opened = opened}, options_.json);
  }

  inline std::vector<GitWorktree> untracked() {
    std::vector<GitWorktree> entries;
    try {
      entries = git_.listed(realDirectory("."), [&](std::string_view path) { return std::ranges::none_of(catalog_.worktrees, [&](const auto &tracked) { return tracked.path == path; }); });
    } catch (const std::exception &) {
      return {};
    }
    return entries;
  }

  inline WorktreeListEntry findOrAdopt() {
    if (const auto entry = find(*options_.branch)) {
      return *entry;
    }
    for (const auto &entry : untracked()) {
      if (entry.branch != *options_.branch) {
        continue;
      }
      const auto root = git_.root(entry.path);
      adopted_path_ = entry.path;
      adopted_branch_ = entry.branch;
      adopted_base_ = git_.currentBranch(root);
      const auto source = sourceWorkspace(root);
      const auto pane = attributedPane();
      const auto reference = coordinator(pane);
      const auto registered = session_.template exchange<WorktreeRegistered>(RegisterWorktree{.source = source, .created_by = pane, .path = adopted_path_, .branch = adopted_branch_, .base = adopted_base_, .coordinator = reference});
      return {.worktree = registered.worktree, .source = source, .path = adopted_path_, .branch = adopted_branch_, .base = adopted_base_};
    }
    throw Failure{"no tracked worktree matches that branch or title", 2};
  }

  inline int exec() {
    const auto entry = findOrAdopt();
    const auto opened = launch(entry.worktree, entry.path);
    if (options_.wait) {
      return wait(opened);
    }
    worktreeLaunch(output_, WorktreeLaunch{.worktree = entry.worktree, .path = entry.path, .branch = entry.branch, .base = entry.base, .opened = opened}, options_.json);
    return 0;
  }

  inline int wait(const PaneOpened &opened) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{options_.timeout};
    constexpr std::uint16_t maximum_rows = 2000;
    constexpr unsigned wait_poll_ms = 250;
    for (;;) {
      const auto reply = session_.template exchange<PaneText>(ReadPane{.pane_id = opened.pane_id, .pane_generation = opened.pane_generation, .rows = maximum_rows, .source = PaneTextSource::recent});
      if (reply.exit_code) {
        auto text = reply.text;
        while (text.ends_with(' ') || text.ends_with('\n')) {
          text.remove_suffix(1);
        }
        if (options_.json) {
          output_.text("{\"pane_id\":").number(opened.pane_id).text(",\"exit_code\":").number(*reply.exit_code).text(",\"truncated\":").boolean(reply.truncated).text(",\"output\":").json(text).text("}\n");
        } else {
          output_.text(text).text("\n");
          if (reply.truncated) {
            std::fprintf(stderr, "telar worktree: older rows were omitted\n");
          }
        }
        return *reply.exit_code >= 0 && *reply.exit_code <= std::numeric_limits<std::uint8_t>::max() ? *reply.exit_code : 1;
      }
      if (std::chrono::steady_clock::now() >= deadline) {
        std::fprintf(stderr, "telar worktree: the command is still running after %us; pane %llu\n", options_.timeout, static_cast<unsigned long long>(opened.pane_id));
        return 3;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds{wait_poll_ms});
    }
  }

  inline void list() {
    Channel agents_channel{memory_, options_.socket, false};
    const auto agents = agents_channel.template exchange<AgentSnapshot>(QueryAgents{});
    std::optional<std::uint64_t> source;
    if (options_.workspace) {
      source = maybeUnsigned(*options_.workspace);
      if (!source) {
        const auto entry = workspaceAt(*options_.workspace);
        if (!entry) {
          throw Failure{"workspace not found", 2};
        }
        source = entry->workspace;
      }
    }
    output_.text(options_.json ? "[" : "BRANCH\tTITLE\tSTATE\tAGENT\tDIFF\tCOMMAND\tPATH\n");
    bool first = true;
    for (const auto &entry : catalog_.worktrees) {
      if (source && entry.source != *source) {
        continue;
      }
      if (options_.json && !first) {
        output_.text(",");
      }
      worktreeEntry(output_, entry, agents.entries, options_.json);
      first = false;
    }
    for (const auto &entry : untracked()) {
      if (options_.json) {
        if (!first) {
          output_.text(",");
        }
        output_.text("{\"worktree_id\":null,\"branch\":").json(entry.branch, JsonEscapes::control).text(",\"path\":").json(entry.path, JsonEscapes::control).text(",\"origin\":\"untracked\",\"agents\":[]}");
      } else {
        output_.text(entry.branch).text("\t-\tuntracked\t-\t-\t-\t").text(entry.path).text("\n");
      }
      first = false;
    }
    if (options_.json) {
      output_.text("]\n");
    }
  }

  inline void open() {
    const auto entry = find(*options_.branch);
    if (!entry) {
      throw Failure{"no tracked worktree matches that branch or title", 2};
    }
    if (!entry->workspace) {
      throw Failure{"nothing was launched in that worktree yet; use `telar worktree exec`", 2};
    }
    const auto clients = session_.template exchange<ClientList>(QueryClients{});
    ClientDescriptor client;
    try {
      client = chooseClient(clients.entries, options_.client);
    } catch (const Failure &) {
      throw Failure{"no UI client is attached; pass --client ID"};
    }
    RequestClientCommand request;
    request.route = {.id = client.id, .generation = client.generation};
    request.action = ClientAction::workspace_select;
    request.target_id = *entry->workspace;
    const auto reply = session_.template exchange<ClientCommandResult>(request);
    if (reply.status == ClientCommandStatus::failed) {
      throw Failure{"the UI client could not open the worktree"};
    }
    if (options_.json) {
      output_.text("{\"worktree_id\":").number(entry->worktree).text(",\"workspace_id\":").number(*entry->workspace).text(",\"client_id\":").number(client.id).text("}\n");
    } else {
      output_.text("opened ").text(entry->branch).text(" in client ").number(client.id).text("\n");
    }
  }

  inline void diff() {
    const auto entry = findOrAdopt();
    const auto against = options_.uncommitted ? std::string{"HEAD"} : git_.line({"git", "-C", entry.path, "merge-base", entry.base.empty() ? "HEAD" : entry.base, "HEAD"});
    std::vector<std::string_view> argv{"git", "-C", entry.path, "--no-pager", "diff"};
    if (options_.stat) {
      argv.push_back("--stat");
    }
    argv.push_back(against);
    git_.run(argv, "GitDiffFailed", true);
  }

  inline void remove() {
    const auto entry = find(*options_.branch);
    if (!entry) {
      throw Failure{"no tracked worktree matches that branch or title", 2};
    }
    std::optional<std::string> root;
    try {
      root = git_.root(entry->path);
    } catch (const std::exception &) {
    }
    if (root && !options_.force && !git_.run({"git", "-C", entry->path, "status", "--porcelain"}, "GitFailed").empty()) {
      throw Failure{"the worktree has local changes; commit them or pass --force"};
    }
    if (options_.force && !confirmRemoval("Remove the worktree and discard its local changes")) {
      throw Failure{"removal cancelled"};
    }
    const bool merged = options_.delete_branch && root && git_.merged(*root, entry->branch);
    if (options_.delete_branch && !merged && !confirmRemoval("Also delete its branch and the commits no other branch has")) {
      throw Failure{"removal cancelled"};
    }
    session_.template exchange<RequestCompleted>(ForgetWorktree{.worktree = entry->worktree});
    if (root) {
      if (options_.force) {
        git_.run({"git", "-C", *root, "worktree", "remove", "--force", "--", entry->path}, "git worktree remove failed");
      } else {
        git_.run({"git", "-C", *root, "worktree", "remove", "--", entry->path}, "git worktree remove failed");
      }
      if (options_.delete_branch) {
        git_.run({"git", "-C", *root, "branch", merged ? "-d" : "-D", "--", entry->branch}, "git branch deletion failed; the branch may not be merged");
      }
    }
    if (options_.json) {
      output_.text("{\"worktree_id\":").number(entry->worktree).text(",\"path\":").json(entry->path).text(",\"branch_deleted\":").boolean(options_.delete_branch).text("}\n");
    } else {
      output_.text("removed ").text(entry->branch).text(" at ").text(entry->path).text("\n");
    }
  }

  // `repository_discovery.find`, with this command's descriptions of its errors.
  inline void resolve() {
    static constexpr std::array<std::pair<std::string_view, const char *>, 4> descriptions{{
        {"RepositoryNotInWorkspace", "that workspace holds another repository"},
        {"AmbiguousRepository", "several clones of this repository are open on the machine; pass --workspace PATH"},
        {"WorkspaceNotFound", "workspace not found"},
        {"NotARepository", "not inside a git repository"},
    }};
    std::optional<std::string> found;
    try {
      found = repository::find(memory_, *options_.repository, options_.workspace, options_.socket);
    } catch (const std::runtime_error &error) {
      const auto description = std::ranges::find(descriptions, std::string_view{error.what()}, &std::pair<std::string_view, const char *>::first);
      if (description == descriptions.end()) {
        throw;
      }

      throw Failure{description->second, description->first == "WorkspaceNotFound" ? 2 : 1};
    }

    if (!found) {
      throw Failure{"no workspace on the machine holds this repository; open one there or pass --workspace PATH"};
    }

    if (options_.json) {
      output_.text("{\"repository\":").json(*options_.repository).text(",\"path\":").json(*found).text("}\n");
    } else {
      output_.text(*found).text("\n");
    }
  }

  Memory &memory_;
  const WorktreeOptions &options_;
  Channel<Memory> catalog_channel_;
  // Views what the catalog channel decoded.
  tbc::view<WorkspaceList, tbc::lt::self> catalog_;
  Channel<Memory> session_;
  WorktreeGit<Memory> git_;
  Output<Memory> output_;
  std::uint64_t verified_generation_ = 0;
  std::string adopted_path_, adopted_branch_, adopted_base_;
};

template <Allocator Memory>
int worktree(Memory &memory, const WorktreeOptions &options) {
  try {
    // The machine's own label runs here like any other create.
    if (options.machine) {
      if (const auto profile = machine::resolve(memory, *options.machine)) {
        WorktreeDispatch dispatch{memory, options, *profile};
        return options.action == WorktreeOptions::Action::fetch ? dispatch.fetch() : dispatch.create();
      }

      if (options.action == WorktreeOptions::Action::fetch) {
        throw Failure{"FetchNeedsAnotherMachine"};
      }
    }

    return WorktreeCommand{memory, options}.run();
  } catch (const Failure &error) {
    const auto message = describeDispatchError(error.what());
    std::fprintf(stderr, "telar worktree: %.*s\n", static_cast<int>(message.size()), message.data());
    return error.status() == 2 || error.code() == FailureCode::worktree_not_found || error.code() == FailureCode::workspace_not_found ? 2 : 1;
  } catch (const std::exception &error) {
    const auto message = describeDispatchError(error.what());
    std::fprintf(stderr, "telar worktree: %.*s\n", static_cast<int>(message.size()), message.data());
    return 1;
  }
}

}
}
