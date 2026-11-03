#pragma once

#include "repository_receive.hpp"
#include "machine_ssh.hpp"
#include "telar_base/text/json_node.hpp"

namespace telar::runtime::cli::repository {

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

// Zig's `repository_prepare.prepare`: bundles `options.from` and has the other
// machine's telar receive it. `capture` runs the given telar words there with
// the bundle as stdin and returns their stdout.
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
