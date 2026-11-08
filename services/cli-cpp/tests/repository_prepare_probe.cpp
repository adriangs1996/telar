#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


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
#include <sys/mman.h>

import std;
import telar.base.memory;
import telar.base.text;
import telar.client.protocol;
import telar.platform.primitives;
import telar.cli.worktree;

namespace {

// The bundle as one read-only mapping, written to the receiving telar's stdin.
class MappedBundle {
public:
  explicit MappedBundle(int descriptor) {
    struct stat state{};
    if (::fstat(descriptor, &state) != 0 || state.st_size <= 0) {
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

}

int main(int argc, char **argv) {
  using namespace telar;
  using namespace telar::runtime;
  using namespace telar::runtime::cli;

  if (argc != 2) {
    return 2;
  }

  SystemAllocator system;
  constexpr std::size_t memory_budget = std::size_t{512} * 1024 * 1024;
  BudgetAllocator memory{system, memory_budget};
  const std::string_view binary = argv[1];
  try {
    const RepositoryOptions options{.action = RepositoryOptions::Action::prepare};
    const auto prepared = repository::prepare(memory, options, binary, [&](std::span<const std::string_view> words, int descriptor) {
      if (::lseek(descriptor, 0, SEEK_CUR) != 0) {
        throw std::runtime_error{"BundleWasNotRewound"};
      }

      std::vector<std::string_view> arguments{binary};
      arguments.insert(arguments.end(), words.begin(), words.end());
      Command command{memory, Launch{.arguments = arguments}, CommandPurpose::configured_helper};
      const MappedBundle bundle{descriptor};
      const std::array input{bundle.text()};
      constexpr std::size_t max_reply = 4 * 1024 * 1024;
      CommandOutput output{memory, max_reply};
      const auto status = output.runWithInputDiagnostics(command, std::chrono::steady_clock::now() + repository::git_timeout, input, [](std::span<const Byte> bytes) {
        writeBytes(STDERR_FILENO, bytes);
        return true;
      });
      if (status != 0 || output.truncated()) {
        throw std::runtime_error{"RepositoryTransferFailed"};
      }

      return std::string{output.text()};
    });
    writeText(prepared.json());
    return 0;
  } catch (const std::exception &error) {
    writeText("telar repository: " + std::string{error.what()} + "\n", STDERR_FILENO);
    return 1;
  }
}
