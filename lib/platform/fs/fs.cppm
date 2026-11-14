module;
#include "tbc/hot_path.hpp"

#include <dirent.h>
#include <limits.h>
#include <sys/stat.h>
#include <sys/types.h>

export module telar.platform.fs;

import std;
import telar.tbc;

export import telar.base.memory.allocators;

import telar.platform.error;
import telar.platform.primitives;

// Interface: telar_platform/private_directory.cppm
export {
  namespace telar::runtime {

    void createPrivateDirectory(std::string_view path);
    FileDescriptor openPrivateParent(std::string_view file_path);

  }
}

// Interface: telar_platform/directory_stream.cppm
export {
  namespace telar::runtime {

    class DirectoryStream {
    public:
      explicit DirectoryStream(int directory);
      explicit DirectoryStream(FileDescriptor iterator);
      ~DirectoryStream();

      DirectoryStream(const DirectoryStream&) = delete;
      DirectoryStream& operator=(const DirectoryStream&) = delete;

      int descriptor() const noexcept;
      const dirent* next();

    private:
      DIR* stream_;
    };

  }
}

// Interface: telar_platform/read_regular_file.cppm
export {
  namespace telar::runtime {

    tbc::view<std::optional<std::string_view>, tbc::lt::a> readRegularFile(std::string_view path, tbc::view<std::span<char>, tbc::lt::a> buffer) noexcept;

  }
}

// Interface: telar_platform/open_beneath.cppm
export {
  namespace telar::runtime {

    FileDescriptor openBeneath(int root, std::string_view path, int flags, mode_t permissions = 0);

  }
}

// Interface: telar_platform/private_file.cppm
export {
  namespace telar::runtime {

    // A private file open for reading, with the size it had when opened; no descriptor when it
    // does not exist.
    struct PrivateFile {
      FileDescriptor file;
      std::size_t size = 0;
    };

    PrivateFile openPrivateFile(int directory, std::string_view name, std::size_t limit);

    // Fills `bytes` from `file` and checks that the file ends there.
    void readPrivateFileBytes(int file, std::span<unsigned char> bytes);

    // Stays in the interface because it is a template over the caller's allocator; it only sizes
    // the caller's buffer.
    template <Allocator Memory>
    TBC_HOT_PATH bool readPrivateFile(int directory, std::string_view name, Vector<unsigned char, Memory>& bytes, std::size_t limit) {
      const auto opened = openPrivateFile(directory, name, limit);
      if (!opened.file) {
        return false;
      }

      bytes.resize(opened.size);
      readPrivateFileBytes(opened.file.get(), bytes);
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
      explicit FileReadError(FileReadFailure failure) noexcept;

      FileReadFailure failure() const noexcept;
      const char* what() const noexcept override;

    private:
      FileReadFailure failure_;
    };

    // The size of the regular file `descriptor` opens, which must be at most `maximum_bytes`.
    std::size_t boundedFileSize(int descriptor, std::size_t maximum_bytes);

    // Fills `bytes` from `descriptor` and checks that the file ends there.
    void readFileBytes(int descriptor, std::span<char> bytes);

    FileDescriptor openSourceFile(const char* path);

    // These two stay in the interface because they are templates over the caller's allocator; they
    // only size the caller's string.
    template <Allocator Memory>
    TBC_HOT_PATH String<Memory> readFileContents(Memory& memory, int descriptor, std::size_t maximum_bytes) {
      const auto size = boundedFileSize(descriptor, maximum_bytes);
      String<Memory> source{AllocatorRef<char, Memory>{memory}};

      source.resize(size);
      readFileBytes(descriptor, source);
      return source;
    }

    template <Allocator Memory>
    TBC_HOT_PATH String<Memory> readFile(Memory& memory, const char* path, std::size_t maximum_bytes) {
      const auto file = openSourceFile(path);

      return readFileContents(memory, file.get(), maximum_bytes);
    }

  }
}

// Interface: telar_platform/rename.cppm
export {
  namespace telar::runtime {

    enum class RenameMode {
      create_only,
      replace,
    };

    int renameAt(int source_directory, const char* source, int destination_directory, const char* destination, RenameMode mode) noexcept;

  }
}

// Interface: telar_platform/resolve_relative_path.cppm
export {
  namespace telar::runtime {

    // Writes to `resolved` the path that `path` names relative to `directory`, with `.` and `..`
    // resolved lexically, and returns its length. `resolved` holds at least
    // `directory.size() + path.size() + 2` characters.
    std::size_t resolvePath(std::string_view directory, std::string_view path, std::span<char> resolved) noexcept;

    std::string_view workingDirectory(std::span<char, PATH_MAX> buffer);

    // These two stay in the interface because they are templates over the caller's allocator; they
    // only size the caller's string.
    template <Allocator Memory>
    TBC_HOT_PATH void resolveRelativePath(String<Memory>& path, std::string_view directory) {
      if (path.empty() || path.front() == '/') {
        return;
      }

      String<Memory> resolved{path.get_allocator()};

      resolved.resize(directory.size() + path.size() + 2);
      resolved.resize(resolvePath(directory, path, resolved));
      path = std::move(resolved);
    }

    template <Allocator Memory>
    TBC_HOT_PATH void resolveAbsolutePath(String<Memory>& path) {
      if (path.starts_with('/')) {
        return;
      }

      std::array<char, PATH_MAX> directory;

      resolveRelativePath(path, workingDirectory(directory));
    }

  }
}

// Interface: telar_platform/temporary_directory.cppm
export {
  namespace telar::runtime {

    class TemporaryDirectory {
    public:
      explicit TemporaryDirectory(std::string_view pattern);
      ~TemporaryDirectory();

      TemporaryDirectory(const TemporaryDirectory&) = delete;
      TemporaryDirectory& operator=(const TemporaryDirectory&) = delete;

      int descriptor() const noexcept;
      std::string_view path() const noexcept;

    private:
      static void removeContents(int directory) noexcept;

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

    int writeDescriptor(int descriptor, std::span<const std::uint8_t> bytes) noexcept;

  }
}

// Interface: telar_platform/write_private_file.cppm
export {
  namespace telar::runtime {

    using PrivateFileMode = RenameMode;

    int writePrivateFile(int directory, std::string_view name, std::span<const std::uint8_t> bytes, PrivateFileMode mode) noexcept;

  }
}
