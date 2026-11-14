module;
#include "tbc/view.hpp"

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#include <sys/syscall.h>
#endif

module telar.platform.fs;

import std;

namespace telar::runtime {
  namespace {

    // Fills `bytes` from `descriptor`, retrying interrupted reads; false when the file ends early or
    // holds more than `size` bytes.
    bool readExactly(int descriptor, void* bytes, std::size_t size) noexcept {
      auto* cursor = static_cast<char*>(bytes);
      std::size_t offset = 0;

      while (offset < size) {
        const auto count = ::read(descriptor, cursor + offset, size - offset);
        if (count < 0 && sys::lastError() == EINTR) {
          continue;
        }

        if (count <= 0) {
          return false;
        }

        offset += static_cast<std::size_t>(count);
      }

      char extra;
      ssize_t count;

      do {
        count = ::read(descriptor, &extra, 1);
      } while (count < 0 && sys::lastError() == EINTR);

      return count == 0;
    }

  }

  void createPrivateDirectory(std::string_view path) {
    if (path.empty() || path.front() != '/' || path.size() >= PATH_MAX || path.find('\0') != std::string_view::npos) {
      throw SystemError{"Invalid absolute private directory", EINVAL};
    }

    std::array<char, PATH_MAX> name{};

    std::copy(path.begin(), path.end(), name.begin());
    for (std::size_t index = 1; index <= path.size(); ++index) {
      if (index != path.size() && name[index] != '/') {
        continue;
      }

      const auto separator = name[index];

      name[index] = '\0';
      if (::mkdir(name.data(), 0700) != 0 && sys::lastError() != EEXIST) {
        throw SystemError{"Create private directory"};
      }

      name[index] = separator;
    }

    FileDescriptor directory{::open(name.data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)};
    struct stat state{};
    if (!directory || ::fstat(directory.get(), &state) != 0) {
      throw SystemError{"Open private directory"};
    }

    if (state.st_uid != ::geteuid()) {
      throw SystemError{"Private directory belongs to another user", EACCES};
    }

    if (::fchmod(directory.get(), 0700) != 0) {
      throw SystemError{"Restrict private directory permissions"};
    }
  }

  FileDescriptor openPrivateParent(std::string_view file_path) {
    const auto separator = file_path.rfind('/');
    if (file_path.empty() || file_path.front() != '/' || file_path.size() >= PATH_MAX || separator == file_path.size() - 1 || file_path.find('\0') != std::string_view::npos) {
      throw SystemError{"invalid absolute runtime file path", EINVAL};
    }

    std::array<char, PATH_MAX> directory{};

    std::copy_n(file_path.data(), std::max<std::size_t>(separator, 1), directory.data());
    FileDescriptor parent{::open(directory.data(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
    struct stat state{};
    if (!parent || ::fstat(parent.get(), &state) != 0) {
      throw SystemError{"open runtime file directory"};
    }

    if (state.st_uid != ::geteuid() || (state.st_mode & 0022) != 0) {
      throw SystemError{"runtime directory must be owned by the user and not writable by others", EACCES};
    }

    return parent;
  }

  DirectoryStream::DirectoryStream(int directory)
      : DirectoryStream(FileDescriptor{::openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)}) {}

  DirectoryStream::DirectoryStream(FileDescriptor iterator) {
    if (!iterator) {
      throw SystemError{"Open directory iterator"};
    }

    stream_ = ::fdopendir(iterator.get());
    if (stream_ == nullptr) {
      throw SystemError{"Create directory iterator"};
    }

    iterator.release();
  }

  DirectoryStream::~DirectoryStream() {
    ::closedir(stream_);
  }

  int DirectoryStream::descriptor() const noexcept {
    return ::dirfd(stream_);
  }

  const dirent* DirectoryStream::next() {
    for (;;) {
      sys::setLastError(0);
      const auto* entry = ::readdir(stream_);
      if (entry == nullptr) {
        if (sys::lastError() != 0) {
          throw SystemError{"Read directory entry"};
        }

        return nullptr;
      }

      const auto* name = entry->d_name;
      const bool current_directory = name[0] == '.' && name[1] == '\0';
      const bool parent_directory = name[0] == '.' && name[1] == '.' && name[2] == '\0';
      if (!current_directory && !parent_directory) {
        return entry;
      }
    }
  }

  tbc::view<std::optional<std::string_view>, tbc::lt::a> readRegularFile(std::string_view path, tbc::view<std::span<char>, tbc::lt::a> buffer) noexcept {
    std::array<char, PATH_MAX> terminated;
    if (path.size() >= terminated.size() || path.contains('\0')) {
      return std::nullopt;
    }

    std::memcpy(terminated.data(), path.data(), path.size());
    terminated[path.size()] = '\0';
    FileDescriptor file{::open(terminated.data(), O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOCTTY)};
    struct stat status{};
    if (!file || ::fstat(file.get(), &status) != 0 || !S_ISREG(status.st_mode)) {
      return std::nullopt;
    }

    std::size_t length = 0;

    while (length < buffer.size()) {
      const auto count = ::read(file.get(), buffer.data() + length, buffer.size() - length);
      if (count > 0) {
        length += static_cast<std::size_t>(count);
      } else if (count == 0) {
        break;
      } else if (sys::lastError() != EINTR) {
        return std::nullopt;
      }
    }

    return std::string_view{buffer.data(), length};
  }

  FileDescriptor openBeneath(int root, std::string_view path, int flags, mode_t permissions) {
    if (path.empty() || path.front() == '/' || path.size() >= PATH_MAX || path.contains('\0')) {
      throw SystemError{"Invalid package-relative path", EINVAL};
    }

    FileDescriptor parent;
    std::array<char, PATH_MAX> name;

    for (;;) {
      const auto separator = path.find('/');
      const auto component = path.substr(0, separator);
      if (component.empty() || component == "." || component == "..") {
        throw SystemError{"Invalid package-relative component", EINVAL};
      }

      std::copy(component.begin(), component.end(), name.begin());
      name[component.size()] = '\0';

      const auto selected_flags = separator == std::string_view::npos ? flags : O_RDONLY | O_DIRECTORY;
      FileDescriptor selected{::openat(parent ? parent.get() : root, name.data(), selected_flags | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC, permissions)};
      if (!selected) {
        throw SystemError{"Open package-relative file"};
      }

      if (separator == std::string_view::npos) {
        return selected;
      }

      parent = std::move(selected);
      path.remove_prefix(separator + 1);
    }
  }

  PrivateFile openPrivateFile(int directory, std::string_view name, std::size_t limit) {
    if (name.empty() || name.size() >= PATH_MAX || name.contains('\0')) {
      throw SystemError{"Invalid private file path", EINVAL};
    }

    std::array<char, PATH_MAX> terminated;

    std::copy(name.begin(), name.end(), terminated.begin());
    terminated[name.size()] = '\0';
    FileDescriptor file{::openat(directory, terminated.data(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)};
    if (!file) {
      if (sys::lastError() == ENOENT) {
        return PrivateFile{.file = FileDescriptor{}};
      }

      throw SystemError{"Open private file"};
    }

    struct stat state{};
    if (::fstat(file.get(), &state) != 0 || !S_ISREG(state.st_mode) || state.st_uid != ::geteuid() || (state.st_mode & 0077) != 0) {
      throw SystemError{"Validate private file", EACCES};
    }

    if (state.st_size < 0 || static_cast<std::uint64_t>(state.st_size) > limit) {
      throw SystemError{"Private file exceeds its limit", EFBIG};
    }

    return {.file = std::move(file), .size = static_cast<std::size_t>(state.st_size)};
  }

  void readPrivateFileBytes(int file, std::span<unsigned char> bytes) {
    if (!readExactly(file, bytes.data(), bytes.size())) {
      throw SystemError{"Private file changed while reading", EIO};
    }
  }

  FileReadError::FileReadError(FileReadFailure failure) noexcept
      : failure_(failure) {}

  FileReadFailure FileReadError::failure() const noexcept {
    return failure_;
  }

  const char* FileReadError::what() const noexcept {
    return failure_ == FileReadFailure::invalid_size ? "Source must be a bounded regular file" : "Source changed while reading";
  }

  std::size_t boundedFileSize(int descriptor, std::size_t maximum_bytes) {
    struct stat metadata{};
    if (::fstat(descriptor, &metadata) != 0 || !S_ISREG(metadata.st_mode) || metadata.st_size < 0 || static_cast<std::uint64_t>(metadata.st_size) > maximum_bytes) {
      throw FileReadError{FileReadFailure::invalid_size};
    }

    return static_cast<std::size_t>(metadata.st_size);
  }

  void readFileBytes(int descriptor, std::span<char> bytes) {
    if (!readExactly(descriptor, bytes.data(), bytes.size())) {
      throw FileReadError{FileReadFailure::changed};
    }
  }

  FileDescriptor openSourceFile(const char* path) {
    FileDescriptor file{::open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW | O_NOCTTY)};
    if (!file) {
      throw SystemError{"Open source file"};
    }

    return file;
  }

  int renameAt(int source_directory, const char* source, int destination_directory, const char* destination, RenameMode mode) noexcept {
#if defined(__APPLE__)
    const auto flags = mode == RenameMode::create_only ? RENAME_EXCL : 0;

    return ::renameatx_np(source_directory, source, destination_directory, destination, flags);
#elif defined(__GLIBC__)
    const auto flags = mode == RenameMode::create_only ? RENAME_NOREPLACE : 0;
    return ::renameat2(source_directory, source, destination_directory, destination, flags);
#else
    // musl declares no renameat2; the kernel call is the same.
    const unsigned flags = mode == RenameMode::create_only ? RENAME_NOREPLACE : 0;
    return static_cast<int>(::syscall(SYS_renameat2, source_directory, source, destination_directory, destination, flags));
#endif
  }

  std::size_t resolvePath(std::string_view directory, std::string_view path, std::span<char> resolved) noexcept {
    std::size_t length = 0;

    for (auto remaining : {directory, path}) {
      while (!remaining.empty()) {
        const auto end = remaining.find('/');
        const auto component = remaining.substr(0, end);
        if (component == "..") {
          const auto slash = std::string_view{resolved.data(), length}.rfind('/');

          length = slash == std::string_view::npos ? 0 : slash;
        } else if (!component.empty() && component != ".") {
          resolved[length++] = '/';
          length = static_cast<std::size_t>(std::ranges::copy(component, resolved.data() + length).out - resolved.data());
        }

        if (end == std::string_view::npos) {
          break;
        }

        remaining.remove_prefix(end + 1);
      }
    }

    if (length == 0) {
      resolved[length++] = '/';
    }

    return length;
  }

  std::string_view workingDirectory(std::span<char, PATH_MAX> buffer) {
    if (::getcwd(buffer.data(), buffer.size()) == nullptr) {
      throw SystemError{"Resolve working directory"};
    }

    return buffer.data();
  }

  TemporaryDirectory::TemporaryDirectory(std::string_view pattern) {
    if (pattern.empty() || pattern.front() != '/' || !pattern.ends_with("XXXXXX") || pattern.size() >= path_.size() || pattern.contains('\0')) {
      throw SystemError{"Invalid temporary directory pattern", EINVAL};
    }

    std::copy(pattern.begin(), pattern.end(), path_.begin());
    path_[pattern.size()] = '\0';
    if (::mkdtemp(path_.data()) == nullptr) {
      throw SystemError{"Create temporary directory"};
    }

    directory_.reset(::open(path_.data(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    if (!directory_ || ::fstat(directory_.get(), &identity_) != 0 || ::fchmod(directory_.get(), 0700) != 0) {
      const auto error = sys::lastError();

      ::rmdir(path_.data());
      throw SystemError{"Open temporary directory", error};
    }

    length_ = pattern.size();
  }

  TemporaryDirectory::~TemporaryDirectory() {
    removeContents(directory_.get());
    struct stat current{};
    if (::lstat(path_.data(), &current) == 0 && current.st_dev == identity_.st_dev && current.st_ino == identity_.st_ino) {
      ::rmdir(path_.data());
    }
  }

  int TemporaryDirectory::descriptor() const noexcept {
    return directory_.get();
  }

  std::string_view TemporaryDirectory::path() const noexcept {
    return {path_.data(), length_};
  }

  void TemporaryDirectory::removeContents(int directory) noexcept {
    try {
      DirectoryStream iterator{directory};

      while (const auto* entry = iterator.next()) {
        FileDescriptor child{::openat(directory, entry->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
        if (child) {
          removeContents(child.get());
          ::unlinkat(directory, entry->d_name, AT_REMOVEDIR);
        } else {
          ::unlinkat(directory, entry->d_name, 0);
        }
      }
    } catch (...) {
    }
  }

  int writeDescriptor(int descriptor, std::span<const std::uint8_t> bytes) noexcept {
    while (!bytes.empty()) {
      const auto count = ::write(descriptor, bytes.data(), bytes.size());
      if (count < 0 && sys::lastError() == EINTR) {
        continue;
      }

      if (count <= 0) {
        return count == 0 ? EIO : sys::lastError();
      }

      bytes = bytes.subspan(static_cast<std::size_t>(count));
    }

    return 0;
  }

  int writePrivateFile(int directory, std::string_view name, std::span<const std::uint8_t> bytes, PrivateFileMode mode) noexcept {
    if (name.empty() || name.size() > NAME_MAX || name.contains('\0') || name.contains('/') || name == "." || name == "..") {
      return EINVAL;
    }

    std::array<char, NAME_MAX + 1> destination;

    std::copy(name.begin(), name.end(), destination.begin());
    destination[name.size()] = '\0';
    constexpr unsigned maximum_attempts = 8;

    for (unsigned attempt = 0; attempt < maximum_attempts; ++attempt) {
      std::uint64_t nonce;

      randomBytes(&nonce, sizeof(nonce));
      std::array<char, 64> temporary;

      std::snprintf(temporary.data(), temporary.size(), ".telar-write-%016llx.tmp", static_cast<unsigned long long>(nonce));
      FileDescriptor file{::openat(directory, temporary.data(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600)};
      if (!file) {
        if (sys::lastError() == EEXIST) {
          continue;
        }

        return sys::lastError();
      }

      const int written = writeDescriptor(file.get(), bytes);
      if (written != 0 || ::fsync(file.get()) != 0) {
        const int failure = written != 0 ? written : sys::lastError();

        file.reset();
        ::unlinkat(directory, temporary.data(), 0);
        return failure;
      }

      file.reset();

      if (renameAt(directory, temporary.data(), directory, destination.data(), mode) != 0) {
        const int failure = sys::lastError();

        ::unlinkat(directory, temporary.data(), 0);
        return failure;
      }

      return 0;
    }

    return EEXIST;
  }

}
