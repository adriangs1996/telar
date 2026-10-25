#pragma once

#include "../memory/allocator.hpp"
#include "../platform/private_directory.hpp"
#include "../platform/private_file.hpp"
#include "../platform/write_private_file.hpp"
#include "records.hpp"
#include <cstdio>
#include <sys/file.h>

namespace telar::runtime::checkpoint {

template <Allocator Memory>
class FileStore {
public:
  using Request = std::span<const Byte>;
  using Result = int;

  explicit FileStore(Memory &memory, std::string_view path)
      : parent_(openPrivateParent(path)),
        name_(path.substr(path.rfind('/') + 1), AllocatorRef<char, Memory>{memory}) {}

  bool load(Vector<Byte, Memory> &bytes) {
    return readPrivateFile(parent_.get(), name_, bytes, maximum_bytes);
  }

  FileDescriptor lock() const {
    std::array<char, NAME_MAX + 1> name;
    const auto length = std::snprintf(name.data(), name.size(), "%s.lock", name_.c_str());
    if (length < 0 || static_cast<std::size_t>(length) >= name.size()) {
      throw SystemError{"Session lock path is too long", ENAMETOOLONG};
    }

    FileDescriptor file{::openat(parent_.get(), name.data(), O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0600)};
    struct stat state{};
    if (!file || ::fstat(file.get(), &state) != 0) {
      throw SystemError{"Open session lock"};
    }
    if (!S_ISREG(state.st_mode) || state.st_uid != ::geteuid() || state.st_nlink != 1 || (state.st_mode & 0077) != 0) {
      throw SystemError{"Unsafe session lock", EACCES};
    }
    while (::flock(file.get(), LOCK_EX) != 0) {
      if (errno != EINTR) {
        throw SystemError{"Lock session"};
      }
    }
    return file;
  }

  Result observe(const Request &bytes) noexcept {
    return writePrivateFile(parent_.get(), name_, bytes, PrivateFileMode::replace);
  }

  void quarantine() noexcept {
    std::array<char, NAME_MAX + 1> destination;
    const auto length = std::snprintf(destination.data(), destination.size(), "%s.corrupt", name_.c_str());
    if (length >= 0 && static_cast<std::size_t>(length) < destination.size()) {
      ::renameat(parent_.get(), name_.c_str(), parent_.get(), destination.data());
    }
  }

  void stop() noexcept {}

  static void setAside(Memory &memory, std::string_view path) {
    const auto parent = openPrivateParent(path);
    const String<Memory> name{path.substr(path.rfind('/') + 1), AllocatorRef<char, Memory>{memory}};
    String<Memory> previous{name, AllocatorRef<char, Memory>{memory}};
    previous += ".previous";
    if (::renameat(parent.get(), name.c_str(), parent.get(), previous.c_str()) != 0 && errno != ENOENT) {
      throw SystemError{"Set previous session aside"};
    }
  }

private:
  FileDescriptor parent_;
  String<Memory> name_;
};

}
