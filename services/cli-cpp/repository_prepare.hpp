#pragma once

#include "repository_receive.hpp"
#include "telar_base/text/json_node.hpp"
#include <sys/mman.h>

namespace telar::runtime::cli::repository {

struct RemoteTarget {
  std::string label;
  std::string program = "telar";
};

template <Allocator Memory>
RemoteTarget resolveTarget(Memory &memory, std::string_view label) {
  const ExecutablePath executable;
  const std::array<std::string_view, 4> argv{executable.view(), "machine", "list", "--json"};
  Command command{memory, Launch{.arguments = argv}, CommandPurpose::configured_helper};
  constexpr std::size_t max_profile_bytes = 32 * 1024;
  CommandOutput output{memory, max_profile_bytes};
  if (output.run(command, std::chrono::steady_clock::now() + git_timeout) != 0 || output.truncated()) {
    throw std::runtime_error{"MachineDispatchUnavailable"};
  }

  const auto profiles = JsonNode<Memory>::parse(memory, output.text());
  const auto *machines = profiles.find("machines");
  const auto *local = profiles.find("local");
  if (machines == nullptr || machines->kind() != JsonKind::array) {
    throw std::runtime_error{"InvalidMachineProfiles"};
  }

  for (const auto &profile : machines->children()) {
    const auto *name = profile.find("label");
    if (name == nullptr || name->text() != label) {
      continue;
    }

    RemoteTarget target{.label = std::string{label}};
    const auto *program = profile.find("telar_path");
    if (program != nullptr && program->kind() == JsonKind::string) {
      target.program = program->text();
    }

    return target;
  }

  if (local != nullptr && local->text() == label) {
    throw std::runtime_error{"PreparationNeedsAnotherMachine"};
  }

  throw std::runtime_error{"UnknownMachine"};
}

class MappedBundle {
public:
  explicit MappedBundle(int descriptor) {
    struct stat state{};
    if (::fstat(descriptor, &state) != 0 || state.st_size <= 0 || static_cast<std::uint64_t>(state.st_size) > max_bundle_bytes) {
      throw std::runtime_error{"InvalidRepositoryTransfer"};
    }

    size_ = static_cast<std::size_t>(state.st_size);
    bytes_ = ::mmap(nullptr, size_, PROT_READ, MAP_PRIVATE, descriptor, 0);
    if (bytes_ == MAP_FAILED) {
      throw std::runtime_error{"RepositoryTransferFailed"};
    }
  }

  ~MappedBundle() {
    ::munmap(bytes_, size_);
  }

  MappedBundle(const MappedBundle &) = delete;
  MappedBundle &operator=(const MappedBundle &) = delete;

  std::string_view text() const {
    return {static_cast<const char *>(bytes_), size_};
  }

private:
  void *bytes_;
  std::size_t size_;
};

template <Allocator Memory>
std::string captureFile(Memory &memory, const RemoteTarget &target, std::span<const std::string_view> words, int input) {
  const ExecutablePath executable;
  std::vector<std::string_view> argv{executable.view(), "--machine", target.label};
  argv.insert(argv.end(), words.begin(), words.end());
  Command command{memory, Launch{.arguments = argv}, CommandPurpose::configured_helper};
  const MappedBundle bundle{input};
  const std::array chunks{bundle.text()};
  constexpr std::size_t max_captured_bytes = 4 * 1024 * 1024;
  CommandOutput output{memory, max_captured_bytes};
  const auto status = output.runWithInputDiagnostics(command, std::chrono::steady_clock::now() + git_timeout, chunks, [](std::span<const Byte> bytes) {
    writeBytes(STDERR_FILENO, bytes);
    return true;
  });
  if (status != 0 || output.truncated()) {
    throw std::runtime_error{"RepositoryTransferFailed"};
  }

  return std::string{output.text()};
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

// The transport receives literal CLI words plus an opened bundle descriptor.
// worktree create --machine can supply the machine package's captureFile here.
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

  const ProcessEnvironment environment;
  const auto base = environment.lookup("TMPDIR");
  const auto temporary = std::format("{}/telar-transfer-{:016x}{:016x}", base.empty() ? "/tmp" : base, randomIdentity(), randomIdentity());
  if (::mkdir(temporary.c_str(), 0700) != 0) {
    throw std::runtime_error{file_transfer::fileError(errno)};
  }

  StagingDirectory cleanup{temporary};
  auto directory = file_transfer::openDirectory(temporary);
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
    git.bundle(ref, bundle.get());
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

template <Allocator Memory>
int run(Memory &memory, const RepositoryOptions &options) {
  try {
    if (options.action == RepositoryOptions::Action::receive) {
      writeText(receive(memory, options).json(true));
    } else {
      const auto target = resolveTarget(memory, *options.machine);
      const auto result = prepare(memory, options, target.program, [&](std::span<const std::string_view> words, int input) { return captureFile(memory, target, words, input); });
      writeText(result.json());
    }

    return 0;
  } catch (const std::exception &error) {
    writeText("telar repository: " + std::string{error.what()} + "\n", STDERR_FILENO);
    return 1;
  }
}

}
