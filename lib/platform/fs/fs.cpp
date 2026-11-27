module telar.platform.fs;

import std;
import telar.sys.posix;
import telar.tbc;
import telar.platform.error;
import telar.base.ds;
import telar.base.text;
#ifdef __linux__
import telar.sys.linux_api;
#endif
#ifdef __APPLE__
import telar.sys.apple;
#endif

namespace telar::runtime {
  namespace {

    constexpr mode_t private_directory_mode = 0700;
    constexpr mode_t private_file_mode = 0600;

    // Fills `bytes` from `descriptor`, retrying interrupted reads; false when the file ends early or
    // holds more than `bytes`.
    bool readExactly(int descriptor, std::span<std::byte> bytes) noexcept {
      std::size_t offset = 0;

      while (offset < bytes.size()) {
        const auto count = ::read(descriptor, bytes.subspan(offset).data(), bytes.size() - offset);
        if (count < 0 && sys::lastError() == EINTR) {
          continue;
        }

        if (count <= 0) {
          return false;
        }

        offset += static_cast<std::size_t>(count);
      }

      char extra = 0;

      for (;;) {
        const auto count = ::read(descriptor, &extra, 1);
        if (count >= 0 || sys::lastError() != EINTR) {
          return count == 0;
        }
      }
    }

    constexpr std::size_t temporary_name_bytes = 64;

    // Writes .telar-write-<16 random hexadecimal digits>.tmp to the zeroed `name`, which keeps
    // its terminating NUL.
    void randomTemporaryName(ds::Array<char, temporary_name_bytes>& name) noexcept {
      constexpr std::string_view prefix = ".telar-write-";
      constexpr std::string_view suffix = ".tmp";
      ds::Array<std::uint8_t, sizeof(std::uint64_t)> nonce{};
      const auto output = name.viewMut();

      randomBytes(nonce.dataMut(), nonce.size());
      std::ranges::copy(prefix, output.begin());
      const auto digits = encodeLowerHex(nonce.view(), output.subspan(prefix.size()));

      std::ranges::copy(suffix, output.subspan(prefix.size() + digits.size()).begin());
    }

    // Copies `text` into `buffer` and ends it with a NUL; the caller checked that both fit.
    template <std::size_t Capacity>
    void copyTerminated(std::string_view text, ds::Array<char, Capacity>& buffer) noexcept {
      std::ranges::copy(text, buffer.viewMut().begin());
      buffer.atMut(text.size()) = '\0';
    }

  }

  void createPrivateDirectory(std::string_view path) {
    if (path.empty() || path.front() != '/' || path.size() >= PATH_MAX || path.contains('\0')) {
      throw SystemError{"Invalid absolute private directory", EINVAL};
    }

    ds::Array<char, PATH_MAX> name{};

    std::ranges::copy(path, name.viewMut().begin());
    for (std::size_t index = 1; index <= path.size(); ++index) {
      if (index != path.size() && name[index] != '/') {
        continue;
      }

      const auto separator = name[index];

      name.atMut(index) = '\0';
      if (::mkdir(name.data(), private_directory_mode) != 0 && sys::lastError() != EEXIST) {
        throw SystemError{"Create private directory"};
      }

      name.atMut(index) = separator;
    }

    const FileDescriptor directory{::open(name.data(), combineFlags(O_RDONLY, O_DIRECTORY, O_CLOEXEC, O_NOFOLLOW))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
    struct stat state{};
    if (!directory || ::fstat(directory.get(), &state) != 0) {
      throw SystemError{"Open private directory"};
    }

    if (state.st_uid != ::geteuid()) {
      throw SystemError{"Private directory belongs to another user", EACCES};
    }

    if (::fchmod(directory.get(), private_directory_mode) != 0) {
      throw SystemError{"Restrict private directory permissions"};
    }
  }

  FileDescriptor openPrivateParent(std::string_view file_path) {
    const auto separator = file_path.rfind('/');
    if (file_path.empty() || file_path.front() != '/' || file_path.size() >= PATH_MAX || separator == file_path.size() - 1 || file_path.contains('\0')) {
      throw SystemError{"invalid absolute runtime file path", EINVAL};
    }

    ds::Array<char, PATH_MAX> directory{};

    std::copy_n(file_path.data(), std::max<std::size_t>(separator, 1), directory.dataMut());
    FileDescriptor parent{::open(directory.data(), combineFlags(O_RDONLY, O_DIRECTORY, O_NOFOLLOW, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
    struct stat state{};
    if (!parent || ::fstat(parent.get(), &state) != 0) {
      throw SystemError{"open runtime file directory"};
    }

    constexpr mode_t writable_by_others = 0022;
    if (state.st_uid != ::geteuid() || (state.st_mode & writable_by_others) != 0) {
      throw SystemError{"runtime directory must be owned by the user and not writable by others", EACCES};
    }

    return parent;
  }

  DirectoryStream::DirectoryStream(int directory)
      : DirectoryStream(FileDescriptor{::openat(directory, ".", combineFlags(O_RDONLY, O_DIRECTORY, O_CLOEXEC))}) {} // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic

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
      const auto* entry = ::readdir(stream_); // NOLINT(concurrency-mt-unsafe): readdir is unsafe only on a stream that another thread reads too, and this stream is the object's own
      if (entry == nullptr) {
        if (sys::lastError() != 0) {
          throw SystemError{"Read directory entry"};
        }

        return nullptr;
      }

      const std::string_view name{std::data(entry->d_name)};
      if (name != "." && name != "..") {
        return entry;
      }
    }
  }

  tbc::val_a<ds::Option<std::string_view>> readRegularFile(std::string_view path, tbc::val_a<std::span<char>> buffer) noexcept {
    ds::Array<char, PATH_MAX> terminated{};
    if (path.size() >= terminated.size() || path.contains('\0')) {
      return ds::none;
    }

    copyTerminated(path, terminated);
    const FileDescriptor file{::open(terminated.data(), combineFlags(O_RDONLY, O_NONBLOCK, O_CLOEXEC, O_NOCTTY))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
    struct stat status{};
    if (!file || ::fstat(file.get(), &status) != 0 || !S_ISREG(status.st_mode)) {
      return ds::none;
    }

    std::size_t length = 0;

    while (length < buffer.size()) {
      const auto count = ::read(file.get(), buffer.subspan(length).data(), buffer.size() - length);
      if (count > 0) {
        length += static_cast<std::size_t>(count);
      } else if (count == 0) {
        break;
      } else if (sys::lastError() != EINTR) {
        return ds::none;
      }
    }

    return std::string_view{buffer.data(), length};
  }

  FileDescriptor openBeneath(int root, std::string_view path, OpenMode mode) {
    if (path.empty() || path.front() == '/' || path.size() >= PATH_MAX || path.contains('\0')) {
      throw SystemError{"Invalid package-relative path", EINVAL};
    }

    FileDescriptor parent;
    ds::Array<char, PATH_MAX> name{};

    for (;;) {
      const auto separator = path.find('/');
      const auto component = path.substr(0, separator);
      if (component.empty() || component == "." || component == "..") {
        throw SystemError{"Invalid package-relative component", EINVAL};
      }

      copyTerminated(component, name);

      const auto selected_flags = separator == std::string_view::npos ? mode.flags : combineFlags(O_RDONLY, O_DIRECTORY);
      FileDescriptor selected{::openat(parent ? parent.get() : root, name.data(), combineFlags(selected_flags, O_NOFOLLOW, O_NONBLOCK, O_NOCTTY, O_CLOEXEC), mode.permissions)}; // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
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

    ds::Array<char, PATH_MAX> terminated{};

    copyTerminated(name, terminated);
    FileDescriptor file{::openat(directory, terminated.data(), combineFlags(O_RDONLY, O_NOFOLLOW, O_NONBLOCK, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
    if (!file) {
      if (sys::lastError() == ENOENT) {
        return PrivateFile{.file = FileDescriptor{}};
      }

      throw SystemError{"Open private file"};
    }

    constexpr mode_t shared_permissions = 0077;
    struct stat state{};
    if (::fstat(file.get(), &state) != 0 || !S_ISREG(state.st_mode) || state.st_uid != ::geteuid() || (state.st_mode & shared_permissions) != 0) {
      throw SystemError{"Validate private file", EACCES};
    }

    if (state.st_size < 0 || std::cmp_greater(state.st_size, limit)) {
      throw SystemError{"Private file exceeds its limit", EFBIG};
    }

    return {.file = std::move(file), .size = static_cast<std::size_t>(state.st_size)};
  }

  void readPrivateFileBytes(int file, std::span<unsigned char> bytes) {
    if (!readExactly(file, std::as_writable_bytes(bytes))) {
      throw SystemError{"Private file changed while reading", EIO};
    }
  }

  template <Allocator Memory>
  bool readPrivateFile(int directory, std::string_view name, ds::Vec<unsigned char, Memory>& bytes, std::size_t limit) {
    const auto opened = openPrivateFile(directory, name, limit);
    if (!opened.file) {
      return false;
    }

    bytes.resize(opened.size);
    readPrivateFileBytes(opened.file.get(), bytes.viewMut());
    return true;
  }

  template bool readPrivateFile<Memory>(int directory, std::string_view name, ds::Vec<unsigned char, Memory>& bytes, std::size_t limit);
  template bool readPrivateFile<ConcurrentMemory>(int directory, std::string_view name, ds::Vec<unsigned char, ConcurrentMemory>& bytes, std::size_t limit);
  template bool readPrivateFile<SystemAllocator>(int directory, std::string_view name, ds::Vec<unsigned char, SystemAllocator>& bytes, std::size_t limit);
  template bool readPrivateFile<BudgetAllocator<SystemAllocator>>(int directory, std::string_view name, ds::Vec<unsigned char, BudgetAllocator<SystemAllocator>>& bytes, std::size_t limit);
  template bool readPrivateFile<ErasingAllocator<Memory>>(int directory, std::string_view name, ds::Vec<unsigned char, ErasingAllocator<Memory>>& bytes, std::size_t limit);
  template bool readPrivateFile<ErasingAllocator<ConcurrentMemory>>(int directory, std::string_view name, ds::Vec<unsigned char, ErasingAllocator<ConcurrentMemory>>& bytes, std::size_t limit);

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
    if (::fstat(descriptor, &metadata) != 0 || !S_ISREG(metadata.st_mode) || metadata.st_size < 0 || std::cmp_greater(metadata.st_size, maximum_bytes)) {
      throw FileReadError{FileReadFailure::invalid_size};
    }

    return static_cast<std::size_t>(metadata.st_size);
  }

  void readFileBytes(int descriptor, std::span<char> bytes) {
    if (!readExactly(descriptor, std::as_writable_bytes(bytes))) {
      throw FileReadError{FileReadFailure::changed};
    }
  }

  FileDescriptor openSourceFile(const char* path) {
    FileDescriptor file{::open(path, combineFlags(O_RDONLY, O_CLOEXEC, O_NONBLOCK, O_NOFOLLOW, O_NOCTTY))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
    if (!file) {
      throw SystemError{"Open source file"};
    }

    return file;
  }

  template <Allocator Memory>
  ds::String<Memory> readFileContents(Memory& memory, int descriptor, std::size_t maximum_bytes) {
    const auto size = boundedFileSize(descriptor, maximum_bytes);
    ds::String<Memory> source{memory};

    source.resize(size);
    readFileBytes(descriptor, source.viewMut());
    return source;
  }

  template <Allocator Memory>
  tbc::val_a<ds::String<Memory>> readFile(tbc::mut_a<Memory> memory, const char* path, std::size_t maximum_bytes) {
    const auto file = openSourceFile(path);

    return readFileContents(memory, file.get(), maximum_bytes);
  }

  template ds::String<Memory> readFileContents<Memory>(Memory& memory, int descriptor, std::size_t maximum_bytes);
  template ds::String<ConcurrentMemory> readFileContents<ConcurrentMemory>(ConcurrentMemory& memory, int descriptor, std::size_t maximum_bytes);
  template ds::String<SystemAllocator> readFileContents<SystemAllocator>(SystemAllocator& memory, int descriptor, std::size_t maximum_bytes);
  template ds::String<BudgetAllocator<SystemAllocator>> readFileContents<BudgetAllocator<SystemAllocator>>(BudgetAllocator<SystemAllocator>& memory, int descriptor, std::size_t maximum_bytes);
  template ds::String<RecyclingAllocator<Memory>> readFileContents<RecyclingAllocator<Memory>>(RecyclingAllocator<Memory>& memory, int descriptor, std::size_t maximum_bytes);
  template ds::String<Memory> readFile<Memory>(Memory& memory, const char* path, std::size_t maximum_bytes);
  template ds::String<ConcurrentMemory> readFile<ConcurrentMemory>(ConcurrentMemory& memory, const char* path, std::size_t maximum_bytes);
  template ds::String<SystemAllocator> readFile<SystemAllocator>(SystemAllocator& memory, const char* path, std::size_t maximum_bytes);
  template ds::String<BudgetAllocator<SystemAllocator>> readFile<BudgetAllocator<SystemAllocator>>(BudgetAllocator<SystemAllocator>& memory, const char* path, std::size_t maximum_bytes);
  template ds::String<RecyclingAllocator<Memory>> readFile<RecyclingAllocator<Memory>>(RecyclingAllocator<Memory>& memory, const char* path, std::size_t maximum_bytes);

  int renameAt(int source_directory, const char* source, int destination_directory, const char* destination, RenameMode mode) noexcept {
#ifdef __APPLE__
    const auto flags = mode == RenameMode::create_only ? static_cast<unsigned>(RENAME_EXCL) : 0U;

    return ::renameatx_np(source_directory, source, destination_directory, destination, flags);
#else
    // glibc's renameat2 and musl, which declares none, both reach this kernel call. No libc
    // header reaches this unit, so __GLIBC__ cannot tell them apart here.
    const unsigned flags = mode == RenameMode::create_only ? RENAME_NOREPLACE : 0;
    return static_cast<int>(::syscall(SYS_renameat2, source_directory, source, destination_directory, destination, flags));
#endif
  }

  std::size_t resolvePath(std::string_view directory, std::string_view path, std::span<char> resolved) noexcept {
    std::size_t length = 0;

    for (auto remaining : {directory, path}) {
      while (!remaining.empty()) {
        const auto end = remaining.find('/');
        const auto component = end == std::string_view::npos ? remaining : std::string_view{remaining.data(), end};
        if (component == "..") {
          const auto slash = std::string_view{resolved.data(), length}.rfind('/');

          length = slash == std::string_view::npos ? 0 : slash;
        } else if (!component.empty() && component != ".") {
          resolved[length++] = '/';
          std::ranges::copy(component, resolved.subspan(length).begin());
          length += component.size();
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

  template <Allocator Memory>
  void resolveRelativePath(ds::String<Memory>& path, std::string_view directory) {
    if (path.empty() || path.view().front() == '/') {
      return;
    }

    ds::String<Memory> resolved{path.memory()};

    resolved.resize(directory.size() + path.size() + 2);
    resolved.resize(resolvePath(directory, path, resolved.viewMut()));
    path = std::move(resolved);
  }

  template <Allocator Memory>
  void resolveAbsolutePath(ds::String<Memory>& path) {
    if (path.view().starts_with('/')) {
      return;
    }

    ds::Array<char, PATH_MAX> directory{};

    resolveRelativePath(path, workingDirectory(directory.viewMut()));
  }

  template void resolveRelativePath<Memory>(ds::String<Memory>& path, std::string_view directory);
  template void resolveRelativePath<ConcurrentMemory>(ds::String<ConcurrentMemory>& path, std::string_view directory);
  template void resolveRelativePath<SystemAllocator>(ds::String<SystemAllocator>& path, std::string_view directory);
  template void resolveRelativePath<BudgetAllocator<SystemAllocator>>(ds::String<BudgetAllocator<SystemAllocator>>& path, std::string_view directory);
  template void resolveAbsolutePath<Memory>(ds::String<Memory>& path);
  template void resolveAbsolutePath<ConcurrentMemory>(ds::String<ConcurrentMemory>& path);
  template void resolveAbsolutePath<SystemAllocator>(ds::String<SystemAllocator>& path);
  template void resolveAbsolutePath<BudgetAllocator<SystemAllocator>>(ds::String<BudgetAllocator<SystemAllocator>>& path);

  TemporaryDirectory::TemporaryDirectory(std::string_view pattern) {
    if (pattern.empty() || pattern.front() != '/' || !pattern.ends_with("XXXXXX") || pattern.size() >= path_.size() || pattern.contains('\0')) {
      throw SystemError{"Invalid temporary directory pattern", EINVAL};
    }

    copyTerminated(pattern, path_);
    if (::mkdtemp(path_.dataMut()) == nullptr) {
      throw SystemError{"Create temporary directory"};
    }

    directory_.reset(::open(path_.data(), combineFlags(O_RDONLY, O_DIRECTORY, O_NOFOLLOW, O_CLOEXEC))); // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
    if (!directory_ || ::fstat(directory_.get(), &identity_) != 0 || ::fchmod(directory_.get(), private_directory_mode) != 0) {
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

  void TemporaryDirectory::removeContents(int directory) noexcept { // NOLINT(misc-no-recursion): descends the temporary tree, one open directory per level
    try {
      DirectoryStream iterator{directory};

      while (const auto* entry = iterator.next()) {
        const char* const name = std::data(entry->d_name);
        const FileDescriptor child{::openat(directory, name, combineFlags(O_RDONLY, O_DIRECTORY, O_NOFOLLOW, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
        if (child) {
          removeContents(child.get());
          ::unlinkat(directory, name, AT_REMOVEDIR);
        } else {
          ::unlinkat(directory, name, 0);
        }
      }
    } catch (...) { // NOLINT(bugprone-empty-catch): removal is best effort, and the destructor that calls it cannot fail
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

    ds::Array<char, NAME_MAX + 1> destination{};

    copyTerminated(name, destination);
    constexpr unsigned maximum_attempts = 8;

    for (unsigned attempt = 0; attempt < maximum_attempts; ++attempt) {
      ds::Array<char, temporary_name_bytes> temporary{};

      randomTemporaryName(temporary);
      FileDescriptor file{::openat(directory, temporary.data(), combineFlags(O_WRONLY, O_CREAT, O_EXCL, O_NOFOLLOW, O_CLOEXEC), private_file_mode)}; // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
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

  FileDescriptor openLockFile(int directory, const char* name) noexcept {
    // XNU can fail openat(O_CREAT) with ENOENT while another process creates the same name;
    // the name exists by then, so the next attempt opens it.
    constexpr unsigned maximum_attempts = 8;
    FileDescriptor file;

    for (unsigned attempt = 0; attempt < maximum_attempts && !file; ++attempt) {
      file.reset(::openat(directory, name, combineFlags(O_RDWR, O_CREAT, O_NOFOLLOW, O_NONBLOCK, O_CLOEXEC), private_file_mode)); // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
      if (!file && sys::lastError() != ENOENT && sys::lastError() != EINTR) {
        break;
      }
    }

    return file;
  }

}
