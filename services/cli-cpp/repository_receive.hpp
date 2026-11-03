#pragma once

#include "repository_discovery.hpp"
#include "repository_options.hpp"
#include "telar_platform/private_file.hpp"
#include <sys/file.h>

namespace telar::runtime::cli::repository {

struct PreparedRepository {
  std::string path;
  std::string commit;
  std::string repository;
  bool reused;

  std::string json(bool receiver = false) const {
    const auto prefix = std::format("{{\"path\":{},\"commit\":{},\"repository\":{},", quoteJson(path), quoteJson(commit), quoteJson(repository));
    return prefix + (receiver ? "\"repository_ready\":true,\"reused\":" + std::string{jsonBoolean(reused)} : "\"reused\":" + std::string{jsonBoolean(reused)} + ",\"repository_ready\":true") + ",\"environment\":\"not_run\"}\n";
  }
};

class StagingDirectory {
public:
  explicit StagingDirectory(std::string path)
      : path_(std::move(path)) {}

  ~StagingDirectory() {
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
