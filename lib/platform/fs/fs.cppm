module;
#include "tbc/view.hpp"

#include <cerrno>
#include <cstdio>
#include <cstdlib>
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

export module telar.platform.fs;

import std;

export import telar.base.memory.allocators;

import telar.platform.error;
import telar.platform.primitives;

// Interface: telar_platform/private_directory.cppm
export {
  namespace telar::runtime {

    inline void createPrivateDirectory(std::string_view path) {
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

    inline FileDescriptor openPrivateParent(std::string_view file_path) {
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

  }
}

// Interface: telar_platform/directory_stream.cppm
export {
  namespace telar::runtime {

    class DirectoryStream {
    public:
      inline explicit DirectoryStream(int directory)
          : DirectoryStream(FileDescriptor{::openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)}) {}

      inline explicit DirectoryStream(FileDescriptor iterator) {
        if (!iterator) {
          throw SystemError{"Open directory iterator"};
        }

        stream_ = ::fdopendir(iterator.get());
        if (stream_ == nullptr) {
          throw SystemError{"Create directory iterator"};
        }

        iterator.release();
      }

      inline ~DirectoryStream() {
        ::closedir(stream_);
      }

      DirectoryStream(const DirectoryStream&) = delete;
      DirectoryStream& operator=(const DirectoryStream&) = delete;

      inline int descriptor() const noexcept {
        return ::dirfd(stream_);
      }

      inline const dirent* next() {
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

    private:
      DIR* stream_;
    };

  }
}

// Interface: telar_platform/read_regular_file.cppm
export {
  namespace telar::runtime {

    inline tbc::view<std::optional<std::string_view>, tbc::lt::a> readRegularFile(std::string_view path, tbc::view<std::span<char>, tbc::lt::a> buffer) noexcept {
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

  }
}

// Interface: telar_platform/open_beneath.cppm
export {
  namespace telar::runtime {

    inline FileDescriptor openBeneath(int root, std::string_view path, int flags, mode_t permissions = 0) {
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

  }
}

// Interface: telar_platform/private_file.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    bool readPrivateFile(int directory, std::string_view name, Vector<unsigned char, Memory>& bytes, std::size_t limit) {
      if (name.empty() || name.size() >= PATH_MAX || name.contains('\0')) {
        throw SystemError{"Invalid private file path", EINVAL};
      }

      std::array<char, PATH_MAX> terminated;

      std::copy(name.begin(), name.end(), terminated.begin());
      terminated[name.size()] = '\0';
      FileDescriptor file{::openat(directory, terminated.data(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)};
      if (!file) {
        if (sys::lastError() == ENOENT) {
          return false;
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

      bytes.resize(static_cast<std::size_t>(state.st_size));
      std::size_t offset = 0;

      while (offset < bytes.size()) {
        const auto count = ::read(file.get(), bytes.data() + offset, bytes.size() - offset);
        if (count < 0 && sys::lastError() == EINTR) {
          continue;
        }

        if (count <= 0) {
          throw SystemError{"Private file changed while reading", EIO};
        }

        offset += static_cast<std::size_t>(count);
      }

      unsigned char extra;
      ssize_t count;

      do {
        count = ::read(file.get(), &extra, 1);
      } while (count < 0 && sys::lastError() == EINTR);

      if (count != 0) {
        throw SystemError{"Private file changed while reading", EIO};
      }

      return true;
    }

  }
}

// Interface: telar_platform/read_file.cppm
export {
  namespace telar::runtime {

    enum class FileReadFailure {
      invalid_size,
      changed,
    };

    class FileReadError : public std::exception {
    public:
      inline explicit FileReadError(FileReadFailure failure) noexcept
          : failure_(failure) {}

      inline FileReadFailure failure() const noexcept {
        return failure_;
      }

      inline const char* what() const noexcept override {
        return failure_ == FileReadFailure::invalid_size ? "Source must be a bounded regular file" : "Source changed while reading";
      }

    private:
      FileReadFailure failure_;
    };

    template <Allocator Memory>
    String<Memory> readFileContents(Memory& memory, int descriptor, std::size_t maximum_bytes) {
      struct stat metadata{};
      if (::fstat(descriptor, &metadata) != 0 || !S_ISREG(metadata.st_mode) || metadata.st_size < 0 || static_cast<std::uint64_t>(metadata.st_size) > maximum_bytes) {
        throw FileReadError{FileReadFailure::invalid_size};
      }

      String<Memory> source{AllocatorRef<char, Memory>{memory}};

      source.resize(static_cast<std::size_t>(metadata.st_size));
      std::size_t offset = 0;

      while (offset < source.size()) {
        const auto count = ::read(descriptor, source.data() + offset, source.size() - offset);
        if (count < 0 && sys::lastError() == EINTR) {
          continue;
        }

        if (count <= 0) {
          throw FileReadError{FileReadFailure::changed};
        }

        offset += static_cast<std::size_t>(count);
      }

      char extra;
      ssize_t extra_count;

      do {
        extra_count = ::read(descriptor, &extra, 1);
      } while (extra_count < 0 && sys::lastError() == EINTR);

      if (extra_count != 0) {
        throw FileReadError{FileReadFailure::changed};
      }

      return source;
    }

    template <Allocator Memory>
    String<Memory> readFile(Memory& memory, const char* path, std::size_t maximum_bytes) {
      FileDescriptor file{::open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW | O_NOCTTY)};
      if (!file) {
        throw SystemError{"Open source file"};
      }

      return readFileContents(memory, file.get(), maximum_bytes);
    }

  }
}

// Interface: telar_platform/rename.cppm
export {
#if defined(__linux__) && !defined(__GLIBC__)
#endif

  namespace telar::runtime {

    enum class RenameMode {
      create_only,
      replace,
    };

    inline int renameAt(int source_directory, const char* source, int destination_directory, const char* destination, RenameMode mode) noexcept {
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

  }
}

// Interface: telar_platform/resolve_relative_path.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    void resolveRelativePath(String<Memory>& path, std::string_view directory) {
      if (path.empty() || path.front() == '/') {
        return;
      }

      String<Memory> combined{directory, path.get_allocator()};

      combined += '/';
      combined += path;
      path.clear();
      std::string_view remaining{combined};

      while (!remaining.empty()) {
        const auto end = remaining.find('/');
        const auto component = remaining.substr(0, end);
        if (component == "..") {
          const auto slash = path.rfind('/');

          path.resize(slash == String<Memory>::npos ? 0 : slash);
        } else if (!component.empty() && component != ".") {
          path += '/';
          path += component;
        }

        if (end == std::string_view::npos) {
          break;
        }

        remaining.remove_prefix(end + 1);
      }

      if (path.empty()) {
        path = "/";
      }
    }

    template <Allocator Memory>
    void resolveAbsolutePath(String<Memory>& path) {
      if (path.starts_with('/')) {
        return;
      }

      std::array<char, PATH_MAX> directory;
      if (::getcwd(directory.data(), directory.size()) == nullptr) {
        throw SystemError{"Resolve working directory"};
      }

      resolveRelativePath(path, directory.data());
    }

  }
}

// Interface: telar_platform/temporary_directory.cppm
export {
  namespace telar::runtime {

    class TemporaryDirectory {
    public:
      inline explicit TemporaryDirectory(std::string_view pattern) {
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

      inline ~TemporaryDirectory() {
        removeContents(directory_.get());
        struct stat current{};
        if (::lstat(path_.data(), &current) == 0 && current.st_dev == identity_.st_dev && current.st_ino == identity_.st_ino) {
          ::rmdir(path_.data());
        }
      }

      TemporaryDirectory(const TemporaryDirectory&) = delete;
      TemporaryDirectory& operator=(const TemporaryDirectory&) = delete;

      inline int descriptor() const noexcept {
        return directory_.get();
      }

      inline std::string_view path() const noexcept {
        return {path_.data(), length_};
      }

    private:
      inline static void removeContents(int directory) noexcept {
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

      std::array<char, PATH_MAX> path_;
      std::size_t length_ = 0;
      FileDescriptor directory_;
      struct stat identity_{};
    };

  }
}

// Interface: telar_platform/write_descriptor.cppm
export {
  namespace telar::runtime {

    inline int writeDescriptor(int descriptor, std::span<const std::uint8_t> bytes) noexcept {
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

  }
}

// Interface: telar_platform/write_private_file.cppm
export {
  namespace telar::runtime {

    using PrivateFileMode = RenameMode;

    inline int writePrivateFile(int directory, std::string_view name, std::span<const std::uint8_t> bytes, PrivateFileMode mode) noexcept {
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
}
