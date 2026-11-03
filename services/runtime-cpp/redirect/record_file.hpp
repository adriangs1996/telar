#pragma once

#include "telar_base/memory/allocator.hpp"
#include "telar_platform/private_directory.hpp"
#include "telar_platform/read_file.hpp"
#include "telar_platform/write_private_file.hpp"
#include <chrono>
#include <optional>
#include <sys/file.h>
#include <thread>

namespace telar::runtime::redirect {

enum class RecordLock { owner, update };

template <Allocator Memory>
class RecordFile {
public:
  explicit RecordFile(Memory &memory, std::string_view name, RecordLock mode = RecordLock::owner)
      : memory_(memory), name_(name, AllocatorRef<char, Memory>{memory}) {
    if (name.empty() || name.size() > 64 || name.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_") != std::string_view::npos) {
      throw std::invalid_argument{"Invalid redirect record name"};
    }
    constexpr std::string_view directory = "/var/run/telar-redirect";
    createPrivateDirectory(directory);
    directory_.reset(::open(directory.data(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    String<Memory> lock_name{name_, AllocatorRef<char, Memory>{memory}};
    lock_name += ".lock";
    lock_.reset(::openat(directory_.get(), lock_name.c_str(), O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600));
    if (!directory_ || !lock_) {
      throw SystemError{"Open redirect recovery lock"};
    }
    validate(lock_.get());
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{6};
    while (::flock(lock_.get(), LOCK_EX | LOCK_NB) != 0) {
      if (mode == RecordLock::owner || errno != EWOULDBLOCK || std::chrono::steady_clock::now() >= deadline) {
        throw SystemError{"Redirect helper already active or recovery update busy"};
      }
      std::this_thread::sleep_for(std::chrono::milliseconds{10});
    }
  }

  std::optional<String<Memory>> load() {
    FileDescriptor file{::openat(directory_.get(), name_.c_str(), O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)};
    if (!file && errno == ENOENT) {
      return std::nullopt;
    }
    if (!file) {
      throw SystemError{"Read redirect recovery record"};
    }
    validate(file.get());
    return readFileContents(memory_, file.get(), 4096);
  }

  void save(std::string_view content) {
    const auto error = writePrivateFile(directory_.get(), name_, {reinterpret_cast<const std::uint8_t *>(content.data()), content.size()}, PrivateFileMode::replace);
    if (error != 0) {
      throw SystemError{"Save redirect recovery record", error};
    }
  }

  void clear() {
    if (::unlinkat(directory_.get(), name_.c_str(), 0) != 0 && errno != ENOENT) {
      throw SystemError{"Remove redirect recovery record"};
    }
  }

private:
  static void validate(int descriptor) {
    struct stat metadata{};
    if (::fstat(descriptor, &metadata) != 0 || !S_ISREG(metadata.st_mode) || metadata.st_uid != 0 || metadata.st_nlink != 1 || (metadata.st_mode & 0077) != 0) {
      throw SystemError{"Unsafe redirect recovery file", EACCES};
    }
  }

  Memory &memory_;
  String<Memory> name_;
  FileDescriptor directory_;
  FileDescriptor lock_;
};

}
