module;
#include "telar_platform/open_directory.h"

export module telar.platform.fs;

import std;
import telar.tbc;

import telar.base.memory.allocators;

import telar.base.memory.sensitive;
import telar.platform.primitives;
import telar.sys.posix;
import telar.base.ds;

// The C function behind open_directory.h, shared with Qt; the owned header stays in this global
// module fragment only.
export {
  using ::telarOpenDirectoryNoFollow;
}

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

    tbc::view<ds::Option<std::string_view>, tbc::lt::a> readRegularFile(std::string_view path, tbc::view<std::span<char>, tbc::lt::a> buffer) noexcept;

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

    // Sizes the caller's buffer and fills it; built in fs.cpp for the base allocators
    // its callers use.
    template <Allocator Memory>
    bool readPrivateFile(int directory, std::string_view name, ds::Vec<unsigned char, Memory>& bytes, std::size_t limit);

    extern template bool readPrivateFile<Memory>(int directory, std::string_view name, ds::Vec<unsigned char, Memory>& bytes, std::size_t limit);
    extern template bool readPrivateFile<ConcurrentMemory>(int directory, std::string_view name, ds::Vec<unsigned char, ConcurrentMemory>& bytes, std::size_t limit);
    extern template bool readPrivateFile<SystemAllocator>(int directory, std::string_view name, ds::Vec<unsigned char, SystemAllocator>& bytes, std::size_t limit);
    extern template bool readPrivateFile<BudgetAllocator<SystemAllocator>>(int directory, std::string_view name, ds::Vec<unsigned char, BudgetAllocator<SystemAllocator>>& bytes, std::size_t limit);
    extern template bool readPrivateFile<ErasingAllocator<Memory>>(int directory, std::string_view name, ds::Vec<unsigned char, ErasingAllocator<Memory>>& bytes, std::size_t limit);
    extern template bool readPrivateFile<ErasingAllocator<ConcurrentMemory>>(int directory, std::string_view name, ds::Vec<unsigned char, ErasingAllocator<ConcurrentMemory>>& bytes, std::size_t limit);

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

    // These two read into a string of the caller's allocator; built in fs.cpp for the base allocators
    // its callers use.
    template <Allocator Memory>
    ds::String<Memory> readFileContents(Memory& memory, int descriptor, std::size_t maximum_bytes);

    template <Allocator Memory>
    ds::String<Memory> readFile(Memory& memory, const char* path, std::size_t maximum_bytes);

    extern template ds::String<Memory> readFileContents<Memory>(Memory& memory, int descriptor, std::size_t maximum_bytes);
    extern template ds::String<ConcurrentMemory> readFileContents<ConcurrentMemory>(ConcurrentMemory& memory, int descriptor, std::size_t maximum_bytes);
    extern template ds::String<SystemAllocator> readFileContents<SystemAllocator>(SystemAllocator& memory, int descriptor, std::size_t maximum_bytes);
    extern template ds::String<BudgetAllocator<SystemAllocator>> readFileContents<BudgetAllocator<SystemAllocator>>(BudgetAllocator<SystemAllocator>& memory, int descriptor, std::size_t maximum_bytes);
    extern template ds::String<RecyclingAllocator<Memory>> readFileContents<RecyclingAllocator<Memory>>(RecyclingAllocator<Memory>& memory, int descriptor, std::size_t maximum_bytes);
    extern template ds::String<Memory> readFile<Memory>(Memory& memory, const char* path, std::size_t maximum_bytes);
    extern template ds::String<ConcurrentMemory> readFile<ConcurrentMemory>(ConcurrentMemory& memory, const char* path, std::size_t maximum_bytes);
    extern template ds::String<SystemAllocator> readFile<SystemAllocator>(SystemAllocator& memory, const char* path, std::size_t maximum_bytes);
    extern template ds::String<BudgetAllocator<SystemAllocator>> readFile<BudgetAllocator<SystemAllocator>>(BudgetAllocator<SystemAllocator>& memory, const char* path, std::size_t maximum_bytes);
    extern template ds::String<RecyclingAllocator<Memory>> readFile<RecyclingAllocator<Memory>>(RecyclingAllocator<Memory>& memory, const char* path, std::size_t maximum_bytes);

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

    // These two resolve a path in a string of the caller's allocator; built in fs.cpp for the base
    // allocators its callers use.
    template <Allocator Memory>
    void resolveRelativePath(ds::String<Memory>& path, std::string_view directory);

    template <Allocator Memory>
    void resolveAbsolutePath(ds::String<Memory>& path);

    extern template void resolveRelativePath<Memory>(ds::String<Memory>& path, std::string_view directory);
    extern template void resolveRelativePath<ConcurrentMemory>(ds::String<ConcurrentMemory>& path, std::string_view directory);
    extern template void resolveRelativePath<SystemAllocator>(ds::String<SystemAllocator>& path, std::string_view directory);
    extern template void resolveRelativePath<BudgetAllocator<SystemAllocator>>(ds::String<BudgetAllocator<SystemAllocator>>& path, std::string_view directory);
    extern template void resolveAbsolutePath<Memory>(ds::String<Memory>& path);
    extern template void resolveAbsolutePath<ConcurrentMemory>(ds::String<ConcurrentMemory>& path);
    extern template void resolveAbsolutePath<SystemAllocator>(ds::String<SystemAllocator>& path);
    extern template void resolveAbsolutePath<BudgetAllocator<SystemAllocator>>(ds::String<BudgetAllocator<SystemAllocator>>& path);

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

      ds::Array<char, PATH_MAX> path_;
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

    // Opens the lock file `name` in `directory` read-write, creating it 0600 when absent:
    // every process that creates the same name at once gets it. An invalid descriptor, with
    // errno set, when it cannot be opened.
    FileDescriptor openLockFile(int directory, const char* name) noexcept;

  }
}
