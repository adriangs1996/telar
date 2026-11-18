#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

import std;
import telar.testing;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.primitives;
import telar.base.memory.allocators;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  void testPrivateDirectory() {
    ds::Array<char, 64> temporary{};

    std::strcpy(temporary.dataMut(), "/tmp/telar-cli-test-XXXXXX");
    check(::mkdtemp(temporary.dataMut()) != nullptr);
    const std::string root = temporary.data();
    const auto path = root + "/parent/child";

    createPrivateDirectory(path);
    struct stat state{};

    check(::stat(path.c_str(), &state) == 0 && (state.st_mode & 0777) == 0700);
    check(::chmod(path.c_str(), 0755) == 0);
    createPrivateDirectory(path);
    check(::stat(path.c_str(), &state) == 0 && (state.st_mode & 0777) == 0700);

    const auto link = root + "/linked";

    check(::symlink(path.c_str(), link.c_str()) == 0);
    bool rejected = false;

    try {
      createPrivateDirectory(link);
    } catch (const SystemError&) {
      rejected = true;
    }

    check(rejected);
    std::filesystem::remove_all(root);
  }

  // Calls `open` and returns the SystemError's code, or 0 when it returned a descriptor.
  template <typename Open>
  int openFailure(Open&& open) {
    try {
      const FileDescriptor file = open();

      check(static_cast<bool>(file));
      return 0;
    } catch (const SystemError& error) {
      return error.code();
    }
  }

  void write(const std::string& path, std::string_view bytes) {
    std::ofstream output{path, std::ios::binary};

    output.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
    check(output.good());
  }

  // Package files are opened component by component beneath the package root: a path that
  // names anything outside it, or reaches it through a link, is refused.
  void testOpenBeneathRefusesEscape() {
    TemporaryDirectory temporary{"/tmp/telar-open-beneath-XXXXXX"};
    const std::string base{temporary.path()};
    const auto root = base + "/package";

    std::filesystem::create_directories(root + "/a");
    write(root + "/a/b", "inside");
    write(base + "/outside", "outside");
    check(::symlink((base + "/outside").c_str(), (root + "/link").c_str()) == 0);
    check(::symlink(base.c_str(), (root + "/up").c_str()) == 0);
    const FileDescriptor directory{::open(root.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)};

    check(static_cast<bool>(directory));
    for (const std::string_view path : {"../outside", "a/../b", "./a/b", "a//b", "/etc/hosts", "", "a/."}) {
      check(openFailure([&] {
        return openBeneath(directory.get(), path, O_RDONLY);
      }) == EINVAL);
    }

    for (const std::string_view path : {"link", "up/outside"}) {
      const auto failure = openFailure([&] {
        return openBeneath(directory.get(), path, O_RDONLY);
      });

      check(failure == ELOOP || failure == ENOTDIR);
    }

    const auto file = openBeneath(directory.get(), "a/b", O_RDONLY);
    struct stat opened{};
    struct stat expected{};

    check(::fstat(file.get(), &opened) == 0 && ::stat((root + "/a/b").c_str(), &expected) == 0);
    check(opened.st_ino == expected.st_ino && opened.st_dev == expected.st_dev);
  }

  // A private file's name is one entry of the directory it is written to.
  void testWritePrivateFileRejectsPathNames() {
    TemporaryDirectory temporary{"/tmp/telar-private-file-XXXXXX"};
    const std::string base{temporary.path()};
    const auto inner = base + "/inner";

    std::filesystem::create_directories(inner);
    const FileDescriptor directory{::open(inner.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
    const ds::Array<std::uint8_t, 3> bytes{'k', 'e', 'y'};
    const std::string too_long(NAME_MAX + 1, 'a');

    check(static_cast<bool>(directory));
    for (const std::string_view name : {std::string_view{"../x"}, std::string_view{"a/b"}, std::string_view{"."}, std::string_view{".."}, std::string_view{}, std::string_view{too_long}}) {
      check(writePrivateFile(directory.get(), name, bytes, PrivateFileMode::replace) == EINVAL);
    }

    check(std::filesystem::is_empty(inner));
    check(std::distance(std::filesystem::directory_iterator{base}, std::filesystem::directory_iterator{}) == 1);
    check(writePrivateFile(directory.get(), std::string(NAME_MAX, 'a'), bytes, PrivateFileMode::replace) == 0);
    check(std::filesystem::file_size(inner + "/" + std::string(NAME_MAX, 'a')) == bytes.size());
  }

  // A private file is read only as the regular file it names: a link planted in its place,
  // even to a private file, is refused, and so is a file over the caller's limit.
  void testPrivateFileRefusesLinkAndOversize() {
    TemporaryDirectory temporary{"/tmp/telar-private-read-XXXXXX"};
    const std::string base{temporary.path()};

    write(base + "/target", "0123456789");
    check(::chmod((base + "/target").c_str(), 0600) == 0);
    check(::symlink((base + "/target").c_str(), (base + "/link").c_str()) == 0);
    check(openFailure([&] {
      return openPrivateFile(temporary.descriptor(), "link", 64).file;
    }) == ELOOP);
    check(openFailure([&] {
      return openPrivateFile(temporary.descriptor(), "target", 9).file;
    }) == EFBIG);
    check(openPrivateFile(temporary.descriptor(), "target", 10).size == 10);
  }

  // Processes that edit one locked file at once each create its lock when none exists yet:
  // all of them get it, so no edit fails for having raced another to the first one.
  void testLockFileCreatedAtOnce() {
    TemporaryDirectory temporary{"/tmp/telar-lock-file-XXXXXX"};
    constexpr int rounds = 20;
    constexpr int openers = 8;

    for (int round = 0; round < rounds; ++round) {
      const auto name = "edit-" + std::to_string(round) + ".lock";
      std::atomic<int> waiting{openers};
      std::atomic<int> failures{0};
      std::vector<std::thread> threads;

      for (int index = 0; index < openers; ++index) {
        threads.emplace_back([&] {
          waiting.fetch_sub(1);
          while (waiting.load() > 0) {
          }

          if (!openLockFile(temporary.descriptor(), name.c_str())) {
            failures.fetch_add(1);
          }
        });
      }

      for (auto& thread : threads) {
        thread.join();
      }

      struct stat state{};

      check(failures.load() == 0, "a lock file created at once failed to open");
      check(::fstatat(temporary.descriptor(), name.c_str(), &state, AT_SYMLINK_NOFOLLOW) == 0 && S_ISREG(state.st_mode) && (state.st_mode & 0077) == 0);
    }
  }

  // Calls `read` and returns how it failed: the FileReadError's failure, or none.
  template <typename Read>
  ds::Option<FileReadFailure> readFailure(Read&& read) {
    try {
      read();
    } catch (const FileReadError& error) {
      return error.failure();
    }

    return ds::none;
  }

  // readFile reads a regular file of at most `maximum_bytes`, opened without following a final
  // link: the configuration and plugin package caps rest on it.
  void testReadFileEnforcesBoundAndType() {
    SystemAllocator memory;
    TemporaryDirectory temporary{"/tmp/telar-read-file-XXXXXX"};
    const std::string base{temporary.path()};
    const auto exact = base + "/exact";
    const auto fifo = base + "/fifo";
    const auto link = base + "/link";

    write(exact, "12345678");
    check(::mkfifo(fifo.c_str(), 0600) == 0);
    check(::symlink(exact.c_str(), link.c_str()) == 0);
    check(readFile(memory, exact.c_str(), 8) == "12345678");
    check(readFailure([&] {
      static_cast<void>(readFile(memory, exact.c_str(), 7));
    }) == FileReadFailure::invalid_size);

    for (const auto& path : {base, fifo}) {
      check(readFailure([&] {
        static_cast<void>(readFile(memory, path.c_str(), 8));
      }) == FileReadFailure::invalid_size,
          path);
    }

    bool refused = false;

    try {
      static_cast<void>(readFile(memory, link.c_str(), 8));
    } catch (const SystemError&) {
      refused = true;
    }

    check(refused);
  }

  String<SystemAllocator> relative(SystemAllocator& memory, std::string_view path, std::string_view directory) {
    String<SystemAllocator> resolved{path, AllocatorRef<char, SystemAllocator>{memory}};

    resolveRelativePath(resolved, directory);
    return resolved;
  }

  // A relative path from the configuration resolves lexically beneath its directory, and `..`
  // at the root stays at the root instead of leaving an empty or relative path.
  void testResolveRelativePathClampsAtRoot() {
    SystemAllocator memory;

    check(relative(memory, "../../x", "/a") == "/x");
    check(relative(memory, "..", "/") == "/");
    check(relative(memory, "./b/../c", "/a") == "/a/c");
    check(relative(memory, "/abs/../path", "/a") == "/abs/../path");

    ds::Array<char, PATH_MAX> current{};

    check(::getcwd(current.dataMut(), current.size()) != nullptr);
    String<SystemAllocator> path{"rel", AllocatorRef<char, SystemAllocator>{memory}};

    resolveAbsolutePath(path);
    check(std::string_view{path} == std::string{current.data()} + "/rel");
  }

  const telar::testing::Case case_private_directory{"fs.private_directory", testPrivateDirectory};
  const telar::testing::Case case_open_beneath{"fs.open_beneath_refuses_escape", testOpenBeneathRefusesEscape};
  const telar::testing::Case case_write_private_file{"fs.write_private_file_rejects_path_names", testWritePrivateFileRejectsPathNames};
  const telar::testing::Case case_private_file_refuses{"fs.private_file_refuses_link_and_oversize", testPrivateFileRefusesLinkAndOversize};
  const telar::testing::Case case_lock_file_created_at_once{"fs.lock_file_created_at_once", testLockFileCreatedAtOnce};
  const telar::testing::Case case_read_file{"fs.read_file_enforces_bound_and_type", testReadFileEnforcesBoundAndType};
  const telar::testing::Case case_resolve_relative{"fs.resolve_relative_path_clamps_at_root", testResolveRelativePathClampsAtRoot};

}
