module telar.runtime.files.operations;

import std;
import telar.tbc;
import telar.sys.posix;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.primitives;
import telar.platform.process;
import telar.runtime.files.entry;
import telar.runtime.transport.connection;
import telar.wire.files;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    using Path = ds::String<ConcurrentMemory>;

    // What a copy reads and writes at a time, and the levels of a directory it follows.
    constexpr std::size_t copy_bytes = std::size_t{256} * 1024;
    constexpr std::size_t copy_depth = 64;
    constexpr mode_t permission_bits = 0777;
    constexpr mode_t private_directory = 0700;
    constexpr mode_t new_file = 0666;
    constexpr std::size_t git_output_bytes = std::size_t{16} * 1024;

    // An absolute path with no `..` in it, which is not the root.
    constexpr bool acceptable(std::string_view path) noexcept {
      if (!path.starts_with('/') || path.size() < 2 || path.size() > FileLimits::path_bytes || path.contains('\0')) {
        return false;
      }

      for (auto rest = path; !rest.empty();) {
        const auto end = rest.find('/');
        const auto component = rest.substr(0, end);
        if (component == "..") {
          return false;
        }

        rest.remove_prefix(end == std::string_view::npos ? rest.size() : end + 1);
      }

      return true;
    }

    constexpr std::string_view trimmed(std::string_view path) noexcept {
      while (path.size() > 1 && path.ends_with('/')) {
        path.remove_suffix(1);
      }

      return path;
    }

    constexpr std::string_view parentOf(std::string_view path) noexcept {
      path = trimmed(path);

      const auto slash = path.find_last_of('/');

      return slash == 0 || slash == std::string_view::npos ? std::string_view{"/"} : path.substr(0, slash);
    }

    constexpr std::string_view nameOf(std::string_view path) noexcept {
      path = trimmed(path);
      return path.substr(path.find_last_of('/') + 1);
    }

    ds::Option<struct stat> statOf(const Path& path) noexcept {
      struct stat status{};
      if (::lstat(path.data(), &status) != 0) {
        return ds::none;
      }

      return status;
    }

    constexpr FileOutcome outcomeOf(int error) noexcept {
      if (error == ENOENT) {
        return FileOutcome::missing;
      }

      return error == EACCES || error == EPERM ? FileOutcome::refused : FileOutcome::failed;
    }

    // Removes what a copy that failed left behind: only what this runtime just wrote.
    void removeCopy(int directory, const char* name, std::size_t depth) noexcept {
      if (::unlinkat(directory, name, 0) == 0 || depth == copy_depth) {
        return;
      }

      FileDescriptor child{::openat(directory, name, combineFlags(O_RDONLY, O_DIRECTORY, O_NOFOLLOW, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
      if (!child) {
        return;
      }

      try {
        DirectoryStream stream{std::move(child)};

        while (const auto* entry = stream.next()) {
          removeCopy(stream.descriptor(), std::data(entry->d_name), depth + 1);
        }
      } catch (const SystemError&) { // NOLINT(bugprone-empty-catch): what could not be listed stays, and the directory with it
      }

      ::unlinkat(directory, name, AT_REMOVEDIR);
    }

    // What a copy carries down the directory it copies.
    struct Copy {
      std::span<Byte> buffer;
      const std::atomic<bool>& cancelled;
    };

    // Copies the file, link or directory `name` of `source` as `to` of `target`, where nothing has
    // that name. Returns 0, or the error that stopped it; what it wrote by then stays for the
    // caller to remove.
    int copyEntry(int source, const char* name, int target, const char* to, std::size_t depth, const Copy& copy) noexcept {
      struct stat status{};
      if (::fstatat(source, name, &status, AT_SYMLINK_NOFOLLOW) != 0) {
        return sys::lastError();
      }

      const auto kind = kindOf(status.st_mode);
      const auto permissions = static_cast<mode_t>(status.st_mode & permission_bits);

      if (kind == FileKind::link) {
        ds::Array<char, PATH_MAX> destination{};
        const auto length = ::readlinkat(source, name, destination.viewMut().data(), destination.size() - 1);

        return length < 0 || ::symlinkat(destination.data(), target, to) != 0 ? sys::lastError() : 0;
      }

      if (kind == FileKind::file) {
        const FileDescriptor input{::openat(source, name, combineFlags(O_RDONLY, O_NOFOLLOW, O_CLOEXEC))};                              // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
        const FileDescriptor output{::openat(target, to, combineFlags(O_WRONLY, O_CREAT, O_EXCL, O_NOFOLLOW, O_CLOEXEC), permissions)}; // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
        if (!input || !output) {
          return sys::lastError();
        }

        for (;;) {
          if (copy.cancelled.load(std::memory_order_relaxed)) {
            return ECANCELED;
          }

          const auto read = ::read(input.get(), copy.buffer.data(), copy.buffer.size());
          if (read < 0 && sys::lastError() == EINTR) {
            continue;
          }

          if (read <= 0) {
            return read < 0 ? sys::lastError() : 0;
          }

          for (std::size_t written = 0; written < static_cast<std::size_t>(read);) {
            const auto count = ::write(output.get(), copy.buffer.data() + written, static_cast<std::size_t>(read) - written);
            if (count < 0 && sys::lastError() != EINTR) {
              return sys::lastError();
            }

            written += count < 0 ? 0 : static_cast<std::size_t>(count);
          }
        }
      }

      if (kind != FileKind::directory) {
        // A socket, a pipe or a device is not copied.
        return 0;
      }

      if (depth == copy_depth) {
        return ELOOP;
      }

      // Writable while it is filled, whatever the source's own permissions.
      if (::mkdirat(target, to, permissions | private_directory) != 0) {
        return sys::lastError();
      }

      FileDescriptor from{::openat(source, name, combineFlags(O_RDONLY, O_DIRECTORY, O_NOFOLLOW, O_CLOEXEC))};     // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
      const FileDescriptor into{::openat(target, to, combineFlags(O_RDONLY, O_DIRECTORY, O_NOFOLLOW, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
      if (!from || !into) {
        return sys::lastError();
      }

      try {
        DirectoryStream stream{std::move(from)};

        while (const auto* entry = stream.next()) {
          const auto* const child = std::data(entry->d_name);
          if (const int failure = copyEntry(stream.descriptor(), child, into.get(), child, depth + 1, copy); failure != 0) {
            return failure;
          }
        }
      } catch (const SystemError&) {
        return EIO;
      }

      return 0;
    }

    // Copies `source` to `target`, which does not exist; nothing stays of a copy that failed.
    int copyPath(ConcurrentMemory& memory, const Path& source, const Path& target, const std::atomic<bool>& cancelled) {
      const Path source_parent{memory, parentOf(source.view())};
      const Path target_parent{memory, parentOf(target.view())};
      const Path source_name{memory, nameOf(source.view())};
      const Path target_name{memory, nameOf(target.view())};
      const FileDescriptor from{::open(source_parent.data(), combineFlags(O_RDONLY, O_DIRECTORY, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
      const FileDescriptor into{::open(target_parent.data(), combineFlags(O_RDONLY, O_DIRECTORY, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
      if (!from || !into) {
        return sys::lastError();
      }

      ds::Vec<Byte, ConcurrentMemory> buffer{memory};

      buffer.resize(copy_bytes);

      const int failure = copyEntry(from.get(), source_name.data(), into.get(), target_name.data(), 0, {.buffer = buffer.viewMut(), .cancelled = cancelled});
      if (failure != 0 && failure != EEXIST) {
        removeCopy(into.get(), target_name.data(), 0);
      }

      return failure;
    }

    // Creates `path` and the directories above it that are missing, for this account alone.
    bool createDirectories(Path& path) noexcept {
      for (std::size_t slash = path.view().find('/', 1);; slash = path.view().find('/', slash + 1)) {
        const bool last = slash == std::string_view::npos;

        if (!last) {
          path.atMut(slash) = '\0';
        }

        const bool made = ::mkdir(path.data(), private_directory) == 0 || sys::lastError() == EEXIST;

        if (!last) {
          path.atMut(slash) = '/';
        }

        if (!made || last) {
          return made;
        }
      }
    }

    // The home of the account, as the runtime's environment names it; empty when it names none.
    std::string_view home() noexcept {
      const char* value = std::getenv("HOME"); // NOLINT(concurrency-mt-unsafe): the runtime does not change its environment once it started

      return value == nullptr || value[0] != '/' ? std::string_view{} : std::string_view{value};
    }

    // Where this account's trash keeps files: the one of its home, or the one of the volume
    // `top` is the root of, as macOS and the XDG trash specification place them.
    tbc::val_a<Path> trashFiles(tbc::mut_a<ConcurrentMemory> memory, std::string_view top) {
      Path directory{memory};

#ifdef __APPLE__
      if (top.empty()) {
        directory.assign(home());
        directory.append("/.Trash");
      } else {
        ds::formatTo(directory, "{}/.Trashes/{}", top == "/" ? std::string_view{} : top, ::getuid());
      }
#else
      if (top.empty()) {
        const char* data = std::getenv("XDG_DATA_HOME"); // NOLINT(concurrency-mt-unsafe): the runtime does not change its environment once it started

        if (data != nullptr && data[0] == '/') {
          directory.assign(data);
        } else {
          directory.assign(home());
          directory.append("/.local/share");
        }

        directory.append("/Trash/files");
      } else {
        ds::formatTo(directory, "{}/.Trash-{}/files", top == "/" ? std::string_view{} : top, ::getuid());
      }
#endif

      return directory;
    }

    // The root of the volume `path` is on: the highest directory above it on the same device.
    tbc::val_a<Path> volumeOf(tbc::mut_a<ConcurrentMemory> memory, std::string_view path, dev_t device) {
      Path top{memory, parentOf(path)};

      while (top.view() != "/") {
        const Path above{memory, parentOf(top.view())};
        struct stat status{};
        if (::lstat(above.data(), &status) != 0 || status.st_dev != device) {
          break;
        }

        top.assign(above.view());
      }

      return top;
    }

#ifndef __APPLE__
    // Where the XDG trash keeps what it knows of a file it holds at `kept`.
    tbc::val_a<Path> trashInfo(tbc::mut_a<ConcurrentMemory> memory, std::string_view kept) {
      constexpr std::string_view files = "/files/";
      Path info{memory};
      const auto at = kept.rfind(files);

      if (at != std::string_view::npos) {
        ds::formatTo(info, "{}/info/{}.trashinfo", kept.substr(0, at), kept.substr(at + files.size()));
      }

      return info;
    }

    // Records where `kept` came from, as the XDG trash specification asks: its path with the
    // bytes outside a URL's escaped, and when it was deleted.
    void writeTrashInfo(ConcurrentMemory& memory, std::string_view kept, std::string_view original) {
      constexpr std::string_view digits = "0123456789ABCDEF";
      constexpr unsigned nibble = 4;
      constexpr unsigned nibble_mask = 0xf;
      Path info = trashInfo(memory, kept);
      if (info.empty()) {
        return;
      }

      Path parent{memory, parentOf(info.view())};
      Path text{memory, "[Trash Info]\nPath="};

      for (const char character : original) {
        const auto byte = static_cast<unsigned char>(character);
        const bool plain = (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || std::string_view{"/-_.~"}.contains(character);

        if (plain) {
          text.push(character);
        } else {
          text.push('%');
          text.push(digits[byte >> nibble]);
          text.push(digits[byte & nibble_mask]);
        }
      }

      const auto now = std::chrono::floor<std::chrono::seconds>(std::chrono::system_clock::now());
      const std::time_t seconds = std::chrono::system_clock::to_time_t(now);
      std::tm local{};

      ::localtime_r(&seconds, &local);
      ds::formatTo(text, "\nDeletionDate={:04}-{:02}-{:02}T{:02}:{:02}:{:02}\n", local.tm_year + 1900, local.tm_mon + 1, local.tm_mday, local.tm_hour, local.tm_min, local.tm_sec); // NOLINT(cppcoreguidelines-avoid-magic-numbers,readability-magic-numbers): tm counts years from 1900 and months from zero

      if (!createDirectories(parent)) {
        return;
      }

      const FileDescriptor file{::open(info.data(), combineFlags(O_WRONLY, O_CREAT, O_EXCL, O_NOFOLLOW, O_CLOEXEC), new_file)}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
      if (file) {
        static_cast<void>(::write(file.get(), text.data(), text.size()));
      }
    }
#endif

  }

  void besideName(ds::String<ConcurrentMemory>& candidate, std::string_view path, unsigned attempt) {
    path = trimmed(path);

    const auto name = nameOf(path);
    const auto dot = name.find_last_of('.');
    // A name that only starts with a dot has no extension.
    const auto stem = dot == std::string_view::npos || dot == 0 ? name.size() : dot;

    candidate.clear();
    ds::formatTo(candidate, "{}{}-{}{}", path.substr(0, path.size() - name.size()), name.substr(0, stem), attempt, name.substr(stem));
  }

  FileChanger::FileChanger(ConcurrentMemory& memory)
      : memory_(memory),
        journal_(memory),
        output_(memory) {}

  void FileChanger::remember(Step step, std::string_view first, std::string_view second, std::uint64_t inode) {
    journal_.push({.step = step, .first = Path{memory_, first}, .second = Path{memory_, second}, .inode = inode});
  }

  ds::Option<FileChanger::Path> FileChanger::trash(std::string_view path, bool copy) const {
    const Path source{memory_, path};
    const auto status = statOf(source);
    if (!status || home().empty()) {
      return ds::none;
    }

    const std::atomic<bool> never{false};
    // The trash of the home first; a file of another volume goes to that volume's.
    Path top{memory_};

    for (int volume = 0; volume < 2; ++volume) {
      Path files = trashFiles(memory_, top.view());
      if (!createDirectories(files)) {
        return ds::none;
      }

      Path kept{memory_};

      ds::formatTo(kept, "{}/{}", files.view(), nameOf(path));

      const Path wanted{memory_, kept.view()};
      bool other_volume = false;

      for (unsigned attempt = 0; attempt <= beside_attempts; ++attempt) {
        if (attempt != 0) {
          besideName(kept, wanted.view(), attempt);
        }

        const int failure = copy ? copyPath(memory_, source, kept, never) : (renameAt(AT_FDCWD, source.data(), AT_FDCWD, kept.data(), RenameMode::create_only) == 0 ? 0 : sys::lastError());
        if (failure == 0) {
#ifndef __APPLE__
          writeTrashInfo(memory_, kept.view(), path);
#endif
          return kept;
        }

        if (failure == EXDEV) {
          other_volume = true;
          break;
        }

        if (failure != EEXIST && failure != ENOTEMPTY) {
          return ds::none;
        }
      }

      if (!other_volume) {
        return ds::none;
      }

      top = volumeOf(memory_, path, status->st_dev);
    }

    return ds::none;
  }

  bool FileChanger::clear(Path& target, bool overwrite, bool& renamed) {
    if (overwrite) {
      auto kept = trash(target.view(), false);
      if (!kept) {
        return false;
      }

      remember(Step::trashed, target.view(), kept->view(), 0);
      return true;
    }

    const Path wanted{memory_, target.view()};

    for (unsigned attempt = 1; attempt <= beside_attempts; ++attempt) {
      besideName(target, wanted.view(), attempt);
      if (!statOf(target)) {
        renamed = true;
        return true;
      }
    }

    return false;
  }

  int FileChanger::git(std::string_view directory, std::span<const std::string_view> arguments, const std::atomic<bool>& cancelled) {
    constexpr std::size_t maximum_words = 8;
    ds::Array<char, PATH_MAX> found{};
    const char* named = std::getenv("PATH"); // NOLINT(concurrency-mt-unsafe): the runtime does not change its environment once it started
    // Kept: what looks a program up may read the environment again.
    const Path path{memory_, named == nullptr ? std::string_view{} : std::string_view{named}};

    output_.clear();
    if (arguments.size() >= maximum_words || path.empty() || !findExecutable({.path = path.view(), .program = "git"}, found.viewMut())) {
      return -1;
    }

    ds::Array<std::string_view, maximum_words> words{};

    words.atMut(0) = found.data();
    std::ranges::copy(arguments, words.viewMut().subspan(1).begin());

    try {
      Command command{memory_, Launch{.cwd = directory, .arguments = words.view().first(arguments.size() + 1)}, CommandPurpose::administration};
      CommandOutput<ConcurrentMemory> output{memory_, git_output_bytes, &cancelled};
      const int status = output.run(command, Clock::now() + git_time);

      output_.assign(output.text());
      return status;
    } catch (const SystemError&) {
      return -1;
    } catch (const RequestError&) {
      return -1;
    }
  }

  FileChanger::Applied FileChanger::create(const FileOperation& operation, bool overwrite) {
    Applied applied{.path = Path{memory_, trimmed(operation.target)}};
    bool renamed = false;
    if (!acceptable(operation.target) || (statOf(applied.path) && !clear(applied.path, overwrite, renamed))) {
      applied.outcome = FileOutcome::refused;
      return applied;
    }

    bool made = false;

    if (operation.kind == FileOperationKind::create_directory) {
      made = ::mkdir(applied.path.data(), permission_bits) == 0;
    } else {
      const FileDescriptor file{::open(applied.path.data(), combineFlags(O_WRONLY, O_CREAT, O_EXCL, O_NOFOLLOW, O_CLOEXEC), new_file)}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic

      made = static_cast<bool>(file);
    }

    if (!made) {
      applied.outcome = outcomeOf(sys::lastError());
      return applied;
    }

    const auto status = statOf(applied.path);

    remember(Step::created, applied.path.view(), {}, status ? static_cast<std::uint64_t>(status->st_ino) : 0);
    applied.outcome = renamed ? FileOutcome::renamed : FileOutcome::done;
    return applied;
  }

  FileChanger::Applied FileChanger::transfer(const FileOperation& operation, bool overwrite) {
    const Path source{memory_, trimmed(operation.source)};
    Applied applied{.path = Path{memory_, trimmed(operation.target)}};
    const auto status = acceptable(operation.source) ? statOf(source) : ds::none;

    if (!status) {
      applied.outcome = acceptable(operation.source) ? FileOutcome::missing : FileOutcome::refused;
      return applied;
    }

    if (!names(*status, operation.identity)) {
      applied.outcome = FileOutcome::stale;
      return applied;
    }

    // A directory does not go inside itself.
    const bool inside = applied.path.view().starts_with(source.view()) && applied.path.view().substr(source.size()).starts_with('/');
    if (!acceptable(operation.target) || inside) {
      applied.outcome = FileOutcome::refused;
      return applied;
    }

    if (applied.path.view() == source.view()) {
      applied.outcome = FileOutcome::done;
      return applied;
    }

    bool renamed = false;
    if (statOf(applied.path) && !clear(applied.path, overwrite, renamed)) {
      applied.outcome = FileOutcome::refused;
      return applied;
    }

    const std::atomic<bool> never{false};
    int failure = 0;
    bool copied = operation.kind == FileOperationKind::copy;

    if (!copied && renameAt(AT_FDCWD, source.data(), AT_FDCWD, applied.path.data(), RenameMode::create_only) != 0) {
      failure = sys::lastError();
      // Another volume takes a copy, and the source goes to the trash once the copy is whole.
      copied = failure == EXDEV;
    }

    if (copied) {
      failure = copyPath(memory_, source, applied.path, never);
    }

    if (failure != 0) {
      applied.outcome = outcomeOf(failure);
      return applied;
    }

    if (!copied) {
      remember(Step::moved, source.view(), applied.path.view(), static_cast<std::uint64_t>(status->st_ino));
    } else {
      const auto made = statOf(applied.path);

      remember(Step::created, applied.path.view(), {}, made ? static_cast<std::uint64_t>(made->st_ino) : 0);
      if (operation.kind == FileOperationKind::move) {
        if (auto kept = trash(source.view(), false)) {
          remember(Step::trashed, source.view(), kept->view(), 0);
        }
      }
    }

    applied.outcome = renamed ? FileOutcome::renamed : FileOutcome::done;
    return applied;
  }

  FileChanger::Applied FileChanger::discard(const FileOperation& operation, const std::atomic<bool>& cancelled) {
    Applied applied{.path = Path{memory_, trimmed(operation.source)}};
    const auto status = acceptable(operation.source) ? statOf(applied.path) : ds::none;

    if (!status) {
      applied.outcome = acceptable(operation.source) ? FileOutcome::missing : FileOutcome::refused;
      return applied;
    }

    if (!names(*status, operation.identity)) {
      applied.outcome = FileOutcome::stale;
      return applied;
    }

    // What git is about to discard is kept in the trash first.
    auto kept = trash(applied.path.view(), true);
    if (!kept) {
      applied.outcome = FileOutcome::refused;
      return applied;
    }

    const ds::Array<std::string_view, 3> arguments{"checkout", "--", nameOf(applied.path.view())};
    if (git(parentOf(applied.path.view()), arguments.view(), cancelled) != 0) {
      applied.outcome = FileOutcome::failed;
      return applied;
    }

    remember(Step::restored, applied.path.view(), kept->view(), 0);
    applied.outcome = FileOutcome::done;
    return applied;
  }

  FileChanger::Applied FileChanger::index(const FileOperation& operation, const std::atomic<bool>& cancelled) {
    Applied applied{.path = Path{memory_, trimmed(operation.source)}};

    if (!acceptable(operation.source)) {
      applied.outcome = FileOutcome::refused;
      return applied;
    }

    const auto name = nameOf(applied.path.view());
    const ds::Array<std::string_view, 3> add{"add", "--", name};
    const ds::Array<std::string_view, 4> reset{"reset", "-q", "--", name};
    const std::span<const std::string_view> arguments = operation.kind == FileOperationKind::stage ? std::span<const std::string_view>{add.view()} : std::span<const std::string_view>{reset.view()};

    applied.outcome = git(parentOf(applied.path.view()), arguments, cancelled) == 0 ? FileOutcome::done : FileOutcome::failed;
    return applied;
  }

  FileChanger::Applied FileChanger::apply(const FileOperation& operation, bool overwrite, const std::atomic<bool>& cancelled) {
    if (cancelled.load(std::memory_order_relaxed)) {
      return {.outcome = FileOutcome::failed, .path = Path{memory_, operation.source.empty() ? operation.target : operation.source}};
    }

    switch (operation.kind) {
    case FileOperationKind::create_file:
    case FileOperationKind::create_directory:
      return create(operation, overwrite);
    case FileOperationKind::move:
    case FileOperationKind::copy:
      return transfer(operation, overwrite);
    case FileOperationKind::restore:
      return discard(operation, cancelled);
    case FileOperationKind::stage:
    case FileOperationKind::unstage:
      return index(operation, cancelled);
    case FileOperationKind::trash:
      break;
    }

    Applied applied{.path = Path{memory_, trimmed(operation.source)}};
    const auto status = acceptable(operation.source) ? statOf(applied.path) : ds::none;

    if (!status) {
      applied.outcome = acceptable(operation.source) ? FileOutcome::missing : FileOutcome::refused;
      return applied;
    }

    if (!names(*status, operation.identity)) {
      applied.outcome = FileOutcome::stale;
      return applied;
    }

    auto kept = trash(applied.path.view(), false);
    if (!kept) {
      applied.outcome = FileOutcome::refused;
      return applied;
    }

    remember(Step::trashed, applied.path.view(), kept->view(), 0);
    applied.outcome = FileOutcome::done;
    return applied;
  }

  void FileChanger::change(const ChangeFiles& request, const std::atomic<bool>& cancelled, EncodedReply<ConcurrentMemory>& reply) {
    journal_.clear();

    // Every operation first, then the results: a result views its path, which stays where it is
    // once nothing more is kept.
    ds::Vec<Applied, ConcurrentMemory> applied{memory_};
    ds::Array<FileResult, FileLimits::maximum_results> results{};

    applied.reserve(request.operations.size());
    for (const auto& operation : request.operations) {
      applied.push(apply(operation, request.overwrite, cancelled));
    }

    for (std::size_t index = 0; index < applied.size(); ++index) {
      results.atMut(index) = {.outcome = applied[index].outcome, .path = applied[index].path.view()};
    }

    reply.send(FilesChanged{.request_id = request.request_id, .undoable = !journal_.empty(), .results = results.view().first(applied.size())});
  }

  FileOutcome FileChanger::revert(const Record& record) const {
    const auto first = statOf(record.first);
    const auto second = record.second.empty() ? ds::none : statOf(record.second);

    switch (record.step) {
    case Step::created:
      if (!first) {
        return FileOutcome::missing;
      }

      if (static_cast<std::uint64_t>(first->st_ino) != record.inode) {
        return FileOutcome::stale;
      }

      return trash(record.first.view(), false) ? FileOutcome::done : FileOutcome::refused;
    case Step::moved:
      if (!second) {
        return FileOutcome::missing;
      }

      if (static_cast<std::uint64_t>(second->st_ino) != record.inode) {
        return FileOutcome::stale;
      }

      return renameAt(AT_FDCWD, record.second.data(), AT_FDCWD, record.first.data(), RenameMode::create_only) == 0 ? FileOutcome::done : FileOutcome::refused;
    case Step::trashed:
    case Step::restored:
      break;
    }

    if (!second) {
      return FileOutcome::missing;
    }

    // What git restored gives way to what it discarded; a trashed file returns only to a free name.
    const auto mode = record.step == Step::restored ? RenameMode::replace : RenameMode::create_only;
    if (renameAt(AT_FDCWD, record.second.data(), AT_FDCWD, record.first.data(), mode) != 0) {
      return FileOutcome::refused;
    }

#ifndef __APPLE__
    const Path info = trashInfo(memory_, record.second.view());

    if (!info.empty()) {
      ::unlink(info.data());
    }
#endif

    return FileOutcome::done;
  }

  void FileChanger::undo(const UndoFileChanges& request, EncodedReply<ConcurrentMemory>& reply) {
    ds::Array<FileResult, FileLimits::maximum_results> results{};
    const auto count = std::min<std::size_t>(journal_.size(), results.size());

    for (std::size_t index = 0; index < count; ++index) {
      const auto& record = journal_[journal_.size() - 1 - index];

      results.atMut(index) = {.outcome = revert(record), .path = record.first.view()};
    }

    reply.send(FilesChanged{.request_id = request.request_id, .undoable = false, .results = results.view().first(count)});
    journal_.clear();
  }

  void FileChanger::commit(const CommitChanges& request, const std::atomic<bool>& cancelled, EncodedReply<ConcurrentMemory>& reply) {
    if (!request.path.starts_with('/')) {
      throw RequestError{FailureCode::invalid_request, "A commit needs an absolute directory"};
    }

    const ds::Array<std::string_view, 3> commit{"commit", "-m", request.message};
    if (git(request.path, commit.view(), cancelled) != 0) {
      throw RequestError{FailureCode::invalid_request, "git did not commit: nothing is staged, or a hook refused it"};
    }

    const ds::Array<std::string_view, 3> last{"log", "-1", "--format=%h%x09%s"};
    std::string_view name;
    std::string_view subject;

    if (git(request.path, last.view(), cancelled) == 0) {
      auto line = output_.view();

      line = line.substr(0, line.find('\n'));

      const auto tab = line.find('\t');
      if (tab != std::string_view::npos && tab <= FileLimits::commit_bytes) {
        name = line.substr(0, tab);
        subject = line.substr(tab + 1, FileLimits::subject_bytes);
      }
    }

    reply.send(ChangesCommitted{.request_id = request.request_id, .commit = name, .subject = subject});
  }

}
