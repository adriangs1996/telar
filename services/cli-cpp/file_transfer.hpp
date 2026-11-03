#pragma once

#include "command_limit.hpp"
#include "telar_platform/file_descriptor.hpp"
#include "telar_platform/rename.hpp"
#include <fcntl.h>
#include <filesystem>
#include <sys/stat.h>
#ifdef __linux__
#include <sys/syscall.h>
#endif

namespace telar::runtime::cli::file_transfer {

inline constexpr std::uint64_t max_bytes = 128 * 1024 * 1024;
inline constexpr std::size_t copy_buffer_bytes = 64 * 1024;

inline const char *fileError(int code) {
  switch (code) {
  case ENOENT:
    return "FileNotFound";
  case ENOTDIR:
    return "NotDir";
  case EACCES:
  case EPERM:
    return "AccessDenied";
  case EEXIST:
    return "PathAlreadyExists";
  case ELOOP:
    return "SymLinkLoop";
  case ENAMETOOLONG:
    return "NameTooLong";
  case ENOSPC:
    return "NoSpaceLeft";
  default:
    return "InputOutput";
  }
}

struct Options {
  enum class Action {
    put,
    get
  };
  Action action;
  std::string path;
  std::uint64_t bytes = 0;

  static Options parse(Arguments words) {
    if (words.size() != 2 && words.size() != 4) {
      throw std::invalid_argument{"InvalidFileArguments"};
    }

    if (!std::string_view{words[1]}.starts_with('/')) {
      throw std::invalid_argument{"AbsoluteFilePathRequired"};
    }

    const std::string_view action = words.front();
    if (action != "put" && action != "get") {
      throw std::invalid_argument{"UnknownFileAction"};
    }

    Options self{.action = action == "put" ? Action::put : Action::get, .path = words[1]};
    if (words.size() == 4) {
      if (self.action != Action::put || std::string_view{words[2]} != "--bytes") {
        throw std::invalid_argument{"InvalidFileArguments"};
      }

      self.bytes = parseUnsigned<std::uint64_t>(words[3]);
    } else if (self.action == Action::put) {
      throw std::invalid_argument{"MissingTransferByteCount"};
    }

    return self;
  }
};

// Walk with directory descriptors: no ancestor, including the final parent,
// may redirect a transfer through a symlink between validation and opening.
inline FileDescriptor openDirectory(std::string_view path, bool create = false) {
  if (!path.starts_with('/')) {
    throw std::runtime_error{"AbsoluteFilePathRequired"};
  }

  FileDescriptor current{::open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
  if (!current) {
    throw std::runtime_error{fileError(errno)};
  }

  std::size_t start = 1;
  while (start < path.size()) {
    const auto end = path.find('/', start);
    const auto component = path.substr(start, end == path.npos ? path.size() - start : end - start);
    start = end == path.npos ? path.size() : end + 1;
    if (component.empty()) {
      continue;
    }

    if (component == "." || component == "..") {
      throw std::runtime_error{"InvalidFilePath"};
    }

    const std::string name{component};
    auto next = ::openat(current.get(), name.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (next < 0 && errno == ENOENT && create) {
      if (::mkdirat(current.get(), name.c_str(), 0700) != 0 && errno != EEXIST) {
        throw std::runtime_error{fileError(errno)};
      }

      next = ::openat(current.get(), name.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    }

    if (next < 0) {
      throw std::runtime_error{fileError(errno)};
    }

    current.reset(next);
  }

  struct stat inode{};
  if (::fstat(current.get(), &inode) != 0) {
    throw std::runtime_error{fileError(errno)};
  }

  if (inode.st_uid != ::getuid() || (inode.st_mode & 0022) != 0) {
    throw std::runtime_error{"UnsafeTransferDirectory"};
  }

  return current;
}

inline FileDescriptor openParent(std::string_view path) {
  const auto slash = path.rfind('/');
  if (slash == path.npos) {
    throw std::runtime_error{"InvalidFilePath"};
  }

  return openDirectory(path.substr(0, slash == 0 ? 1 : slash));
}

inline FileDescriptor openRegular(int parent, const char *name) {
  FileDescriptor file{::openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)};
  if (!file) {
    throw std::runtime_error{errno == ENOENT ? "FileNotFound" : "UnsafeTransferFile"};
  }

  struct stat inode{};
  if (::fstat(file.get(), &inode) != 0 || !S_ISREG(inode.st_mode) || inode.st_uid != ::getuid() || inode.st_nlink != 1) {
    throw std::runtime_error{"UnsafeTransferFile"};
  }

  return file;
}

inline void checkSize(std::uint64_t size) {
  if (size > max_bytes) {
    reportCommandLimit({.name = "file_transfer.max_bytes", .noun = "bytes", .value = max_bytes, .requested = size});
    throw std::runtime_error{"FileTransferLimit"};
  }
}

inline std::uint64_t copy(int input, int output) {
  std::array<Byte, copy_buffer_bytes> buffer;
  std::uint64_t total = 0;
  for (;;) {
    const auto count = ::read(input, buffer.data(), buffer.size());
    if (count < 0 && errno == EINTR) {
      continue;
    }

    if (count < 0) {
      throw std::runtime_error{fileError(errno)};
    }

    if (count == 0) {
      return total;
    }

    total += static_cast<std::uint64_t>(count);
    checkSize(total);
    writeBytes(output, std::span{buffer}.first(static_cast<std::size_t>(count)));
  }
}

inline void publish(int parent, const char *temporary, const char *name) {
#if defined(__APPLE__) || defined(__linux__)
  const auto result = renameAt(parent, temporary, parent, name, RenameMode::create_only);
#else
  const auto result = ::linkat(parent, temporary, parent, name, 0);
  if (result == 0) {
    ::unlinkat(parent, temporary, 0);
  }
#endif
  if (result != 0) {
    throw std::runtime_error{fileError(errno)};
  }
}

inline void transfer(const Options &options) {
  if (options.action == Options::Action::put) {
    checkSize(options.bytes);
  }

  auto parent = openParent(options.path);
  const auto slash = options.path.rfind('/');
  const auto name = options.path.substr(slash + 1);
  if (name.empty() || name == "." || name == "..") {
    throw std::runtime_error{"InvalidFilePath"};
  }

  if (options.action == Options::Action::get) {
    auto file = openRegular(parent.get(), name.c_str());
    struct stat inode{};
    if (::fstat(file.get(), &inode) != 0) {
      throw std::runtime_error{fileError(errno)};
    }

    checkSize(static_cast<std::uint64_t>(inode.st_size));
    copy(file.get(), STDOUT_FILENO);
    return;
  }

  const auto temporary = std::format(".telar-file-{:016x}{:016x}", randomIdentity(), randomIdentity());
  FileDescriptor file{::openat(parent.get(), temporary.c_str(), O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600)};
  if (!file) {
    throw std::runtime_error{fileError(errno)};
  }

  try {
    const auto size = copy(STDIN_FILENO, file.get());
    if (size != options.bytes) {
      throw std::runtime_error{"FileTransferInterrupted"};
    }

    if (::fsync(file.get()) != 0) {
      throw std::runtime_error{fileError(errno)};
    }

    publish(parent.get(), temporary.c_str(), name.c_str());
    writeText(std::format("{{\"bytes\":{},\"published\":true}}\n", size));
  } catch (...) {
    ::unlinkat(parent.get(), temporary.c_str(), 0);
    throw;
  }
}

inline int run(const Options &options) {
  try {
    transfer(options);
    return 0;
  } catch (const std::exception &error) {
    writeText("telar file: " + std::string{error.what()} + "\n", STDERR_FILENO);
    return 1;
  }
}

}
