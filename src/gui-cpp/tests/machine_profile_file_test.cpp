#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "assertions.hpp"
#include "../core/memory.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <charconv>
#include <concepts>
#include <cstring>
#include <string_view>
#include <system_error>
#include <span>
#include "telar_client/codecs/telar_value_codec.hpp"
#include <algorithm>
#include "telar_base/memory/fixed_text.hpp"
#include <optional>
#include "telar_base/memory/allocator.hpp"
#include <exception>
#include <bit>
#include <limits>
#include <new>
#include "telar_client/codecs/telar_wire.hpp"
#include <sys/param.h>
#include <cerrno>
#include "telar_platform/file_descriptor.hpp"
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <stop_token>
#include <dirent.h>
#include <cstdlib>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <future>
#include <iostream>
#include <string>
#include <thread>

#include "core/memory.hpp"


import telar.gui.machines.profile_store;
import telar.gui.machines.discovery;
import telar.gui.platform.profile_file;
import telar.platform;

namespace {

using namespace telar::gui;
using telar::gui::platform::InsecureProfileFile;
using telar::gui::platform::ProfileFile;
using telar::gui::test::require;
using telar::runtime::TemporaryDirectory;

struct Random {
  std::uint8_t next = 1;

  void fill(std::span<std::uint8_t> output) {
    std::ranges::fill(output, 0);
    output.back() = next++;
  }
};

template <typename Operation>
void refusesInsecureFile(Operation operation) {
  bool rejected = false;
  try {
    operation();
  } catch (const InsecureProfileFile &) {
    rejected = true;
  }

  require(rejected, "non-private, non-regular and symlink files must be refused before reading or locking");
}

TemporaryDirectory temporaryDirectory() {
  return TemporaryDirectory{(std::filesystem::temp_directory_path() / "telar-machine-profiles-XXXXXX").string()};
}

void replacementCreatesPrivateFilesAndKeepsTheLockInode() {
  const auto directory = temporaryDirectory();
  const auto parent = std::filesystem::path{directory.path()} / "settings";
  const auto path = (parent / "machines.json").string();
  ProfileFile file{path};
  SystemAllocator system;
  constexpr std::size_t allocation_budget = std::size_t{128} * 1024;
  BudgetAllocator memory{system, allocation_budget};
  MachineProfileStore store{memory, file};
  require(store.load().rows().empty(), "missing profile files and missing parent directories must load as empty");
  Random random;
  const std::array edit{MachineEdit{.kind = MachineEditKind::add, .label = "build", .value = "dev@build"}};
  static_cast<void>(store.change(edit, random, "local"));
  struct stat file_state{};
  struct stat parent_state{};
  struct stat lock_before{};
  const auto lock_path = path + ".lock";
  require(::stat(path.c_str(), &file_state) == 0 && ::stat(parent.c_str(), &parent_state) == 0 && ::stat(lock_path.c_str(), &lock_before) == 0, "committing must create both private files and their parent");
  constexpr mode_t permission_mask = 0777;
  constexpr mode_t file_mode = 0600;
  constexpr mode_t directory_mode = 0700;
  require((file_state.st_mode & permission_mask) == file_mode && (lock_before.st_mode & permission_mask) == file_mode && (parent_state.st_mode & permission_mask) == directory_mode, "profile data and locks must remain owner-only inside an owner-only directory");
  const std::array rename{MachineEdit{.kind = MachineEditKind::rename, .label = "build", .value = "renamed"}};
  static_cast<void>(store.change(rename, random, "local"));
  struct stat lock_after{};
  require(::stat(lock_path.c_str(), &lock_after) == 0 && lock_after.st_ino == lock_before.st_ino && lock_after.st_dev == lock_before.st_dev, "replacements must retain the shared lock inode for CLI and other windows");
  require(store.load().rows().front().label() == "renamed" && memory.liveBytes() == 0, "native replacements must reload complete JSON and release temporary storage");
}

void readsAndLocksRejectUnsafeFilesystemNodes() {
  const auto directory = temporaryDirectory();
  const auto parent = std::filesystem::path{directory.path()};
  const auto path = (parent / "machines.json").string();
  ProfileFile file{path};
  SystemAllocator memory;
  {
    std::ofstream source{path};
    source << "private source";
  }

  constexpr mode_t shared_file_mode = 0640;
  require(::chmod(path.c_str(), shared_file_mode) == 0, "prepare a group-readable profile fixture");
  refusesInsecureFile([&] {
    static_cast<void>(file.read(memory));
  });
  std::filesystem::remove(path);
  std::filesystem::create_directory(path);
  refusesInsecureFile([&] {
    static_cast<void>(file.read(memory));
  });
  std::filesystem::remove(path);
  constexpr mode_t private_file_mode = 0600;
  require(::mkfifo(path.c_str(), private_file_mode) == 0, "prepare a nonblocking FIFO fixture");
  refusesInsecureFile([&] {
    static_cast<void>(file.read(memory));
  });
  std::filesystem::remove(path);
  std::filesystem::create_symlink(parent / "missing-target", path);
  refusesInsecureFile([&] {
    static_cast<void>(file.read(memory));
  });
  std::filesystem::remove(path);
  const auto lock_path = path + ".lock";
  std::filesystem::create_symlink(parent / "missing-target", lock_path);
  refusesInsecureFile([&] {
    static_cast<void>(file.lock());
  });
  std::filesystem::remove(lock_path);
  {
    const std::ofstream lock{lock_path};
  }

  require(::chmod(lock_path.c_str(), shared_file_mode) == 0, "prepare a group-readable lock fixture");
  refusesInsecureFile([&] {
    static_cast<void>(file.lock());
  });
}

void readsRefuseSourcesBeyondTheProfileFileBudget() {
  const auto directory = temporaryDirectory();
  const auto path = (std::filesystem::path{directory.path()} / "machines.json").string();
  {
    std::ofstream source{path};
    source << std::string(MachineLimits::file_bytes + 1, ' ');
  }

  constexpr mode_t private_file_mode = 0600;
  require(::chmod(path.c_str(), private_file_mode) == 0, "prepare the private oversized-file fixture");
  ProfileFile file{path};
  SystemAllocator system;
  BudgetAllocator memory{system, MachineLimits::file_bytes};
  bool rejected = false;
  try {
    static_cast<void>(file.read(memory));
  } catch (const telar::runtime::SystemError &error) {
    require(error.code() == EFBIG, "an oversized profile must retain the file-size error");
    rejected = true;
  }

  require(rejected && memory.liveBytes() == 0, "oversized sources must be refused before allocating their unbounded content");
}

void concurrentTransactionsRetainEveryWriter() {
  const auto directory = temporaryDirectory();
  const auto path = (std::filesystem::path{directory.path()} / "machines.json").string();
  constexpr std::size_t writers = 8;
  std::array<std::exception_ptr, writers> errors{};
  std::array<std::jthread, writers> threads;
  for (std::size_t index = 0; index < writers; ++index) {
    threads[index] = std::jthread{[&, index] {
      try {
        SystemAllocator memory;
        ProfileFile file{path};
        MachineProfileStore store{memory, file};
        Random random{.next = static_cast<std::uint8_t>(index + 1)};
        const auto label = "machine" + std::to_string(index);
        const auto destination = "dev@host" + std::to_string(index);
        const std::array edits{MachineEdit{.kind = MachineEditKind::add, .label = label, .value = destination}};
        static_cast<void>(store.change(edits, random, "local"));
      } catch (...) {
        errors[index] = std::current_exception();
      }
    }};
  }

  for (auto &thread : threads) {
    thread.join();
  }

  for (const auto &error : errors) {
    if (error) {
      std::rethrow_exception(error);
    }
  }

  SystemAllocator memory;
  ProfileFile file{path};
  MachineProfileStore store{memory, file};
  const auto profiles = store.load();
  require(profiles.rows().size() == writers, "independent concurrent writers must reload under one shared kernel lock without losing another edit");
  for (std::size_t index = 0; index < writers; ++index) {
    require(profiles.find("machine" + std::to_string(index)).has_value(), "every concurrent machine addition must survive");
  }
}

void failedRenameRemovesItsTemporaryFileAndRetainsTheDestination() {
  const auto directory = temporaryDirectory();
  const auto parent = std::filesystem::path{directory.path()};
  const auto path = (parent / "machines.json").string();
  std::filesystem::create_directory(path);
  ProfileFile file{path};
  const auto transaction = file.lock();
  bool failed = false;
  try {
    transaction.replace("{\"version\":1,\"machines\":[]}\n");
  } catch (const telar::runtime::SystemError &) {
    failed = true;
  }

  require(failed && std::filesystem::is_directory(path), "a failed atomic rename must preserve the original destination");
  for (const auto &entry : std::filesystem::directory_iterator{parent}) {
    require(entry.path().filename() == "machines.json" || entry.path().filename() == "machines.json.lock", "failed replacements must remove their owned temporary file");
  }
}

void transactionsKeepTheirOpenedDirectoryAcrossPathReplacement() {
  const auto directory = temporaryDirectory();
  const auto base = std::filesystem::path{directory.path()};
  const auto original = base / "settings";
  const auto moved = base / "moved";
  ProfileFile file{(original / "machines.json").string()};
  const auto transaction = file.lock();
  std::filesystem::rename(original, moved);
  std::filesystem::create_directory(original);
  constexpr std::string_view source = "{\"version\":1,\"machines\":[]}\n";
  transaction.replace(source);
  SystemAllocator memory;
  const auto saved = transaction.read(memory);
  require(saved && telar::textView(*saved) == source, "a transaction must read and replace through the same held directory descriptor");
  require(std::filesystem::exists(moved / "machines.json") && !std::filesystem::exists(original / "machines.json"), "replacing a directory path must not redirect an in-flight transaction into a new directory");
}

void waitingForAnotherWriterCanBeCancelledBeforeGuiShutdown() {
  const auto directory = temporaryDirectory();
  const auto path = (std::filesystem::path{directory.path()} / "machines.json").string();
  ProfileFile first{path};
  std::optional<platform::ProfileFileTransaction> held{first.lock()};
  std::stop_source cancellation;
  ProfileFile waiting{path, cancellation.get_token()};
  auto result = std::async(std::launch::async, [&] {
    try {
      static_cast<void>(waiting.lock());
    } catch (const platform::ProfileOperationCancelled &) {
      return true;
    }

    return false;
  });

  constexpr auto blocked_probe = std::chrono::milliseconds{20};
  constexpr auto cancellation_limit = std::chrono::seconds{1};
  const auto blocked = result.wait_for(blocked_probe) == std::future_status::timeout;
  cancellation.request_stop();
  const auto completed = result.wait_for(cancellation_limit) == std::future_status::ready;
  held.reset();
  const auto cancelled = result.get();
  require(blocked && completed && cancelled, "a waiting profile job must stop before the other writer releases its file lock");
}

}

int main() {
  try {
    replacementCreatesPrivateFilesAndKeepsTheLockInode();
    readsAndLocksRejectUnsafeFilesystemNodes();
    readsRefuseSourcesBeyondTheProfileFileBudget();
    concurrentTransactionsRetainEveryWriter();
    failedRenameRemovesItsTemporaryFileAndRetainsTheDestination();
    transactionsKeepTheirOpenedDirectoryAcrossPathReplacement();
    waitingForAnotherWriterCanBeCancelledBeforeGuiShutdown();
  } catch (const telar::runtime::SystemError &error) {
    std::cerr << error.what() << ": " << error.code() << " " << std::system_category().message(error.code()) << '\n';

    return 1;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
