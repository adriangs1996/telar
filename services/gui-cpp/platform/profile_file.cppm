module;
#include <limits>
#include <utility>
#include <concepts>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <new>
#include <vector>
#include <cstring>
#include <type_traits>
#include <cstdio>

#include <cstdint>

#include "clipboard_image_source.hpp"
#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cstddef>
#include <poll.h>
#include <span>
#include <stdexcept>
#include <time.h>
#include <unistd.h>

#include <atomic>
#include <optional>

#include <sys/stat.h>

#include <sys/param.h>

#include <exception>
#include <fcntl.h>
#include <limits.h>
#include <stop_token>
#include <string_view>

#include <string>

export module telar.gui.platform.profile_file;

import telar.base.diagnostics;
import telar.client.protocol;
import telar.gui.attachments.catalog;
import telar.gui.core.primitives;
import telar.platform.primitives;

// This class completes the forward declaration in the Objective-C++ ABI.


export import telar.gui.machines.discovery;

export import telar.platform;

// Interface: platform/awake_clock.cppm
export {
namespace telar::gui::platform {

struct AwakeClock {
  [[nodiscard]] static std::uint64_t nowNanoseconds() noexcept;
};

}
}

// Interface: platform/clipboard_image_pipe.cppm
export {
namespace telar::gui::platform {

struct ClipboardImagePipeLimits {
  std::size_t source_bytes = AttachmentLimits::maximum_source_bytes;
  std::size_t png_bytes = AttachmentLimits::maximum_png_bytes;
};

class ClipboardImagePipe {
public:
  static constexpr std::chrono::milliseconds timeout{5000};

  template <Allocator Memory>
  [[nodiscard]] inline static SensitiveBytes<Memory> read(Memory &memory, int descriptor, ClipboardImagePipeLimits limits = {}) {
    if (descriptor < 0) {
      throw ClipboardImageFailure{ClipboardImageError::read_failed};
    }

    SensitiveBytes<Memory> bytes{memory};
    Chunk chunk;
    const auto deadline = now() + timeout;
    while (true) {
      waitReadable(descriptor, deadline);
      const auto count = ::read(descriptor, chunk.bytes.data(), chunk.bytes.size());
      if (count < 0 && (errno == EINTR || errno == EAGAIN)) {
        continue;
      }

      if (count < 0) {
        throw ClipboardImageFailure{ClipboardImageError::read_failed};
      }

      if (count == 0) {
        if (bytes.size() == 0) {
          throw ClipboardImageFailure{ClipboardImageError::no_image};
        }

        return bytes;
      }

      const auto size = static_cast<std::size_t>(count);
      if (size > limits.source_bytes - bytes.size()) {
        throw ClipboardImageFailure{ClipboardImageError::source_bytes};
      }

      if (size > limits.png_bytes - bytes.size()) {
        throw ClipboardImageFailure{ClipboardImageError::png_bytes};
      }

      bytes.append(std::span{chunk.bytes}.first(size), std::min(limits.source_bytes, limits.png_bytes));
    }
  }

private:
  static constexpr std::size_t chunk_bytes = std::size_t{16} * 1024;

  struct Chunk {
    std::array<std::byte, chunk_bytes> bytes{};

    Chunk() = default;
    Chunk(const Chunk &) = delete;
    Chunk &operator=(const Chunk &) = delete;
    Chunk(Chunk &&) = delete;
    Chunk &operator=(Chunk &&) = delete;

    inline ~Chunk() {
      eraseSensitiveBytes(bytes);
    }
  };

  [[nodiscard]] inline static std::chrono::milliseconds now() {
    timespec time{};
    if (::clock_gettime(CLOCK_MONOTONIC, &time) != 0) {
      throw std::runtime_error{"ClockFailed"};
    }

    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::seconds{time.tv_sec}) + std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::nanoseconds{time.tv_nsec});
  }

  inline static void waitReadable(int descriptor, std::chrono::milliseconds deadline) {
    while (true) {
      const auto remaining = deadline - now();
      if (remaining.count() <= 0) {
        throw ClipboardImageFailure{ClipboardImageError::read_failed};
      }

      pollfd waiting{.fd = descriptor, .events = POLLIN, .revents = 0};
      const auto ready = ::poll(&waiting, 1, static_cast<int>(remaining.count()));
      if (ready < 0 && errno == EINTR) {
        continue;
      }

      if (ready <= 0 || (static_cast<unsigned>(waiting.revents) & static_cast<unsigned>(POLLERR | POLLNVAL)) != 0) {
        throw ClipboardImageFailure{ClipboardImageError::read_failed};
      }

      return;
    }
  }
};

}
}

// Interface: platform/clipboard_image_transfer.cppm
export extern "C++" {
namespace telar::gui::platform {

class ClipboardImageTransfer {
public:
  inline void fail(ClipboardImageError error) noexcept {
    if (failed_.load(std::memory_order_relaxed)) {
      return;
    }

    error_ = error;
    failed_.store(true, std::memory_order_release);
  }

  [[nodiscard]] inline std::optional<ClipboardImageError> failure() const noexcept {
    if (failed_.load(std::memory_order_acquire)) {
      return error_;
    }

    return std::nullopt;
  }

private:
  ClipboardImageError error_ = ClipboardImageError::read_failed;
  std::atomic<bool> failed_ = false;
};

}
}

// Interface: platform/file_stamp.cppm
export {
namespace telar::gui::platform {

enum class FileSymlinks : std::uint8_t {
  follow,
  inspect,
};

struct FileStamp {
  std::uint64_t size = 0;
  std::int64_t modified_seconds = 0;
  std::int64_t modified_nanoseconds = 0;
  std::uint32_t kind = 0;

  bool operator==(const FileStamp &) const = default;

  [[nodiscard]] inline static std::optional<FileStamp> read(const char *path, FileSymlinks symlinks = FileSymlinks::follow) noexcept {
    struct stat status{};
    const auto result = symlinks == FileSymlinks::follow ? ::stat(path, &status) : ::lstat(path, &status);
    if (result != 0) {
      return {};
    }

#ifdef __APPLE__
    const auto modified = status.st_mtimespec;
#else
    const auto modified = status.st_mtim;
#endif

    return FileStamp{.size = static_cast<std::uint64_t>(status.st_size), .modified_seconds = modified.tv_sec, .modified_nanoseconds = modified.tv_nsec, .kind = static_cast<std::uint32_t>(status.st_mode & S_IFMT)};
  }
};

}
}

// Interface: platform/path_limits.cppm
export {
namespace telar::gui::platform {

struct PathLimits {
  static constexpr std::size_t path_bytes = PATH_MAX;
  static constexpr std::size_t component_bytes = NAME_MAX;
};

}
}

// Interface: platform/profile_file.cppm
export {
namespace telar::gui::platform {

class InsecureProfileFile final : public std::runtime_error {
public:
  inline InsecureProfileFile()
      : std::runtime_error("InsecureFile") {}
};

class ProfileFile;

class ProfileOperationCancelled final : public std::exception {
public:
  [[nodiscard]] inline const char *what() const noexcept override {
    return "Machine profile operation cancelled";
  }
};

template <Allocator Memory>
[[nodiscard]] std::optional<Vector<Byte, Memory>> readProfileSource(Memory &memory, int directory, std::string_view name) {
  Vector<Byte, Memory> bytes{AllocatorRef<Byte, Memory>{memory}};
  try {
    if (!runtime::readPrivateFile(directory, name, bytes, MachineLimits::file_bytes)) {
      return std::nullopt;
    }
  } catch (const runtime::SystemError &error) {
    if (error.code() == EACCES || error.code() == ELOOP || error.code() == EISDIR) {
      throw InsecureProfileFile{};
    }

    throw;
  }

  return bytes;
}

class ProfileFileTransaction {
  friend class ProfileFile;

public:
  ProfileFileTransaction(const ProfileFileTransaction &) = delete;
  ProfileFileTransaction &operator=(const ProfileFileTransaction &) = delete;
  ProfileFileTransaction(ProfileFileTransaction &&) noexcept = default;
  ProfileFileTransaction &operator=(ProfileFileTransaction &&) noexcept = default;
  ~ProfileFileTransaction() = default;

  template <Allocator Memory>
  [[nodiscard]] inline std::optional<Vector<Byte, Memory>> read(Memory &memory) const {
    return readProfileSource(memory, parent_.get(), name_.data());
  }

  void replace(std::string_view source) const;

private:
  ProfileFileTransaction(runtime::FileDescriptor parent, runtime::FileDescriptor lock, std::string_view name);

  runtime::FileDescriptor parent_;
  runtime::FileDescriptor lock_;
  std::array<char, PathLimits::component_bytes + 1> name_{};
};

class ProfileFile {
public:
  explicit ProfileFile(std::string_view path, std::stop_token stop = {});

  template <Allocator Memory>
  [[nodiscard]] inline std::optional<Vector<Byte, Memory>> read(Memory &memory) const {
    return readProfileSource(memory, AT_FDCWD, path());
  }

  [[nodiscard]] std::string_view path() const noexcept;
  [[nodiscard]] ProfileFileTransaction lock() const;

private:
  std::array<char, PathLimits::path_bytes> path_{};
  std::size_t path_length_ = 0;
  std::size_t name_offset_ = 0;
  std::stop_token stop_;
};

}
}

// Interface: platform/runtime_endpoint.cppm
export {
namespace telar::gui::platform::runtime_endpoint {
// The socket of the user's own runtime, which `telar server endpoint` starts in the background
// when none runs. telar runs through the user's login shell, so a runtime started from a
// Finder or login launch gets the PATH, EDITOR and SHELL a terminal would, and so do its panes.
// Blocks until telar answers or a deadline passes; throws when it fails.
std::string resolve();
std::string program();
}
}

// Interface: platform/shared_image_source.cppm
export {
namespace telar::gui::platform {

class SharedImageSource {
public:
  explicit SharedImageSource(std::string_view name);
  ~SharedImageSource() = default;
  SharedImageSource(const SharedImageSource &) = delete;
  SharedImageSource &operator=(const SharedImageSource &) = delete;
  SharedImageSource(SharedImageSource &&) noexcept = default;
  SharedImageSource &operator=(SharedImageSource &&) noexcept = default;

  [[nodiscard]] bool read(std::span<std::uint8_t> destination) const noexcept;

private:
  runtime::FileDescriptor descriptor_;
};

}
}
