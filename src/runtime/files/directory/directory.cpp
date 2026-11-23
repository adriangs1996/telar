module telar.runtime.files.directory;

import std;
import telar.sys.posix;
import telar.platform.fs;
import telar.platform.primitives;
import telar.runtime.files.entry;
import telar.runtime.transport.connection;
import telar.wire.files;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    // The files with several names a measure remembers, so each counts once.
    constexpr std::size_t remembered_links = std::size_t{64} * 1024;
    // A block of `st_blocks`, whatever the file system's own.
    constexpr std::uint64_t block_bytes = 512;

    constexpr char lowered(char character) noexcept {
      return character >= 'A' && character <= 'Z' ? static_cast<char>(character - 'A' + 'a') : character;
    }

    [[noreturn]] void refuse(int error) {
      if (error == EACCES || error == EPERM) {
        throw RequestError{FailureCode::permission_denied, "This account may not read the directory"};
      }

      throw RequestError{FailureCode::invalid_request, "A listing needs a directory that exists"};
    }

  }

  bool listsBefore(std::string_view left, bool left_directory, std::string_view right, bool right_directory) noexcept {
    if (left_directory != right_directory) {
      return left_directory;
    }

    const auto folded = std::lexicographical_compare_three_way(left.begin(), left.end(), right.begin(), right.end(), [](char first, char second) {
      return lowered(first) <=> lowered(second);
    });

    return folded == 0 ? left < right : folded < 0;
  }

  DirectoryReader::DirectoryReader(ConcurrentMemory& memory)
      : path_(memory),
        names_(memory),
        items_(memory),
        counted_(memory) {}

  std::string_view DirectoryReader::nameOf(const Item& item) const {
    return std::string_view{names_.data(), names_.size()}.substr(item.name, item.name_size);
  }

  void DirectoryReader::read(std::string_view path, bool continued) {
    if (!path.starts_with('/')) {
      throw RequestError{FailureCode::invalid_request, "A listing needs an absolute directory"};
    }

    const auto held = continued && path_.view() == path ? read_ : ds::Option<FileIdentity>{};

    // Nothing is held until the directory is read whole: a read that fails leaves no half of one.
    read_ = ds::none;
    path_.assign(path);

    FileDescriptor directory{::open(path_.data(), combineFlags(O_RDONLY, O_DIRECTORY, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
    struct stat opened{};
    if (!directory || ::fstat(directory.get(), &opened) != 0) {
      refuse(sys::lastError());
    }

    const auto identity = identityOf(opened);
    if (held && *held == identity) {
      read_ = identity;
      return;
    }

    names_.clear();
    items_.clear();
    total_ = 0;

    DirectoryStream stream{std::move(directory)};
    const int descriptor = stream.descriptor();

    while (const auto* entry = stream.next()) {
      const auto* const terminated = std::data(entry->d_name);
      const std::string_view name{terminated};
      struct stat status{};

      // A file that is still arriving is no entry yet.
      if (arriving(name)) {
        continue;
      }

      ++total_;
      if (name.size() > FileLimits::name_bytes || items_.size() == kept_entries || ::fstatat(descriptor, terminated, &status, AT_SYMLINK_NOFOLLOW) != 0) {
        continue;
      }

      const auto kind = kindOf(status.st_mode);
      bool lists_as_directory = kind == FileKind::directory;

      // A link lists as what it points to; one that points nowhere lists as a file.
      if (struct stat target{}; kind == FileKind::link && ::fstatat(descriptor, terminated, &target, 0) == 0) {
        lists_as_directory = S_ISDIR(target.st_mode);
      }

      items_.push({
          .name = static_cast<std::uint32_t>(names_.size()),
          .name_size = static_cast<std::uint16_t>(name.size()),
          .kind = kind,
          .directory = lists_as_directory,
          .size = kind == FileKind::directory ? 0 : static_cast<std::uint64_t>(std::max<off_t>(0, status.st_size)),
          .identity = identityOf(status),
      });

      names_.extend(std::span<const char>{name});
    }

    std::ranges::sort(items_.viewMut(), [&](const Item& left, const Item& right) {
      return listsBefore(nameOf(left), left.directory, nameOf(right), right.directory);
    });

    read_ = identity;
  }

  void DirectoryReader::list(const ListDirectory& request, EncodedReply<ConcurrentMemory>& reply) {
    // The first page reads the directory as it is now, which is what reading it again asks for.
    read(request.path, request.skip != 0);

    ds::Array<DirectoryEntry, FileLimits::maximum_entries> entries{};
    const auto first = std::min<std::size_t>(request.skip, items_.size());
    const auto count = std::min<std::size_t>(request.limit, items_.size() - first);

    for (std::size_t index = 0; index < count; ++index) {
      const auto& item = items_[first + index];

      entries.atMut(index) = {.name = nameOf(item), .kind = item.kind, .directory = item.directory, .size = item.size, .identity = item.identity};
    }

    reply.send(DirectoryContents{.request_id = request.request_id, .path = request.path, .skip = static_cast<std::uint32_t>(first), .total = total_, .entries = entries.view().first(count)});
  }

  void DirectoryReader::add(int parent, const char* name, std::size_t depth, Measure& measure) {                  // NOLINT(misc-no-recursion): a tree is walked measured_depth directories deep at most
    FileDescriptor directory{::openat(parent, name, combineFlags(O_RDONLY, O_DIRECTORY, O_NOFOLLOW, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
    if (!directory) {
      // One this account may not open is counted as what its entry takes, which its parent added.
      return;
    }

    if (depth == measured_depth) {
      measure.complete = false;
      return;
    }

    DirectoryStream stream{std::move(directory)};
    const int descriptor = stream.descriptor();

    while (const auto* entry = stream.next()) {
      if (measure.cancelled.load(std::memory_order_relaxed) || Clock::now() >= measure.deadline) {
        measure.complete = false;
        return;
      }

      const auto* const terminated = std::data(entry->d_name);
      struct stat status{};
      if (::fstatat(descriptor, terminated, &status, AT_SYMLINK_NOFOLLOW) != 0) {
        continue;
      }

      // A file with several names takes its blocks once.
      if (status.st_nlink > 1 && !S_ISDIR(status.st_mode)) {
        const auto inode = static_cast<std::uint64_t>(status.st_ino);
        if (counted_.contains(inode)) {
          continue;
        }

        if (counted_.size() < remembered_links) {
          counted_.insert(inode, std::monostate{});
        }
      }

      measure.bytes += static_cast<std::uint64_t>(std::max<std::int64_t>(0, status.st_blocks)) * block_bytes;
      if (S_ISDIR(status.st_mode)) {
        add(descriptor, terminated, depth + 1, measure);
      }
    }
  }

  void DirectoryReader::measure(const MeasureDirectory& request, const std::atomic<bool>& cancelled, EncodedReply<ConcurrentMemory>& reply) {
    read(request.path, true);

    const FileDescriptor directory{::open(path_.data(), combineFlags(O_RDONLY, O_DIRECTORY, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
    if (!directory) {
      refuse(sys::lastError());
    }

    ds::Array<DirectorySize, FileLimits::maximum_entries> sizes{};
    std::size_t measured = 0;
    const auto first = std::min<std::size_t>(request.skip, items_.size());
    const auto count = std::min<std::size_t>(request.limit, items_.size() - first);
    const auto deadline = Clock::now() + measure_time;

    for (std::size_t index = 0; index < count; ++index) {
      const auto& item = items_[first + index];
      if (item.kind != FileKind::directory) {
        continue;
      }

      // Its name follows the names before it; the listing's own bytes hold no terminator.
      ds::Array<char, FileLimits::name_bytes + 1> terminated{};
      const auto name = nameOf(item);

      std::ranges::copy(name, terminated.viewMut().begin());
      Measure measure{.deadline = deadline, .cancelled = cancelled};

      counted_.clear();
      if (cancelled.load(std::memory_order_relaxed) || Clock::now() >= deadline) {
        measure.complete = false;
      } else {
        add(directory.get(), terminated.data(), 0, measure);
      }

      sizes.atMut(measured++) = {.name = name, .bytes = measure.bytes, .complete = measure.complete};
    }

    reply.send(DirectorySizes{.request_id = request.request_id, .path = request.path, .sizes = sizes.view().first(measured)});
  }

}
