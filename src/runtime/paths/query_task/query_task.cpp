module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.paths.query_task;

import telar.platform.error;
import telar.runtime.platform.git_status;
import telar.sys.posix;
import telar.base.ds;

namespace telar::runtime {

  template <Allocator Memory>
  FuzzyMatch<Memory>::FuzzyMatch(Memory& memory)
      : matrix_(memory) {
    matrix_.resize(2 * maximum_needle * maximum_path);
  }

  template <Allocator Memory>
  ds::Option<std::int32_t> FuzzyMatch<Memory>::score(std::string_view path, std::string_view query, std::span<std::uint16_t> positions) {
    if (query.empty()) {
      return 0;
    }

    if (query.size() > maximum_needle || query.size() > path.size()) {
      return ds::none;
    }

    ds::Array<std::uint16_t, maximum_needle> first_matches;
    std::size_t offset = 0;

    for (std::size_t matched = 0; matched < query.size(); ++matched) {
      const char wanted = lower(query[matched]);

      while (offset < path.size() && lower(path[offset]) != wanted) {
        ++offset;
      }

      if (offset == path.size()) {
        return ds::none;
      }

      first_matches.atMut(matched) = static_cast<std::uint16_t>(offset);
      if (!positions.empty()) {
        positions[matched] = first_matches[matched];
      }

      ++offset;
    }

    if (path.size() > maximum_path) {
      return minimum_score / 2;
    }

    if (path.size() == query.size()) {
      return std::numeric_limits<std::int32_t>::max() / 2;
    }

    ds::Array<std::int32_t, maximum_path> bonuses;
    char previous = '/';

    for (std::size_t index = 0; index < path.size(); ++index) {
      bonuses.atMut(index) = bonus(previous, path[index]);
      previous = path[index];
    }

    const bool retain_rows = !positions.empty();

    for (std::size_t index = 0; index < query.size(); ++index) {
      const auto current = retain_rows ? index : index % 2;
      const auto preceding = retain_rows ? (index == 0 ? 0 : index - 1) : 1 - current;
      const auto ending = row(current, false);
      const auto best = row(current, true);
      const auto previous_ending = row(preceding, false);
      const auto previous_best = row(preceding, true);
      const int gap = index + 1 == query.size() ? trailing_gap : inner_gap;
      const char wanted = lower(query[index]);
      auto running = minimum_score;
      // Earlier columns cannot reach this query prefix; later columns leave too few bytes for its suffix.
      const auto alignment_end = path.size() - (query.size() - index - 1);

      for (std::size_t column = first_matches[index]; column < alignment_end; ++column) {
        if (lower(path[column]) != wanted) {
          ending[column] = minimum_score;
          running = plus(running, gap);
          best[column] = running;
          continue;
        }

        auto cell = minimum_score;

        if (index == 0) {
          cell = (static_cast<int>(column) * leading_gap) + bonuses[column];
        } else if (column != 0) {
          cell = std::max(plus(previous_best[column - 1], bonuses[column]), plus(previous_ending[column - 1], consecutive_score));
        }

        ending[column] = cell;
        running = std::max(cell, plus(running, gap));
        best[column] = running;
      }
    }

    if (retain_rows) {
      bool required = false;
      std::size_t column = path.size();

      for (std::size_t index = query.size(); index != 0;) {
        --index;
        while (column > first_matches[index]) {
          --column;
          const auto cell = row(index, false)[column];
          if (cell == minimum_score || (!required && cell != row(index, true)[column])) {
            continue;
          }

          required = index != 0 && column != 0 && cell == plus(row(index - 1, false)[column - 1], consecutive_score);
          positions[index] = static_cast<std::uint16_t>(column);
          break;
        }
      }
    }

    return row(retain_rows ? query.size() - 1 : (query.size() - 1) % 2, true)[path.size() - 1];
  }

  template <Allocator Memory>
  char FuzzyMatch<Memory>::lower(char value) noexcept {
    return value >= 'A' && value <= 'Z' ? static_cast<char>(value + ('a' - 'A')) : value;
  }

  template <Allocator Memory>
  std::int32_t FuzzyMatch<Memory>::plus(std::int32_t value, int increment) noexcept {
    return value == minimum_score ? minimum_score : value + increment;
  }

  template <Allocator Memory>
  int FuzzyMatch<Memory>::bonus(char previous, char value) noexcept {
    const char folded = lower(value);
    if (!((folded >= 'a' && folded <= 'z') || (value >= '0' && value <= '9'))) {
      return 0;
    }

    switch (previous) {
    case '/':
      return 900;
    case '-':
    case '_':
    case ' ':
      return 800;
    case '.':
      return 600;
    default:
      return previous >= 'a' && previous <= 'z' && value >= 'A' && value <= 'Z' ? 700 : 0;
    }
  }

  template <Allocator Memory>
  std::span<std::int32_t> FuzzyMatch<Memory>::row(std::size_t index, bool best) noexcept {
    return matrix_.viewMut().subspan(((index * 2) + static_cast<unsigned>(best)) * maximum_path, maximum_path);
  }

  template class FuzzyMatch<SystemAllocator>;
  template class FuzzyMatch<ConcurrentMemory>;

  template <Allocator Memory>
  PathIndexStorage<Memory>::PathIndexStorage(Memory& memory)
      : memory_(memory) {
    bytes_ = static_cast<char*>(memory_.allocate(maximum_bytes, alignof(char)));
    if (bytes_ == nullptr) {
      throw std::bad_alloc{};
    }

    entries_ = static_cast<IndexedPath*>(memory_.allocate(entry_bytes, alignof(IndexedPath)));
    if (entries_ == nullptr) {
      memory_.deallocate(bytes_, maximum_bytes, alignof(char));
      throw std::bad_alloc{};
    }
  }

  template <Allocator Memory>
  PathIndexStorage<Memory>::~PathIndexStorage() {
    memory_.deallocate(entries_, entry_bytes, alignof(IndexedPath));
    memory_.deallocate(bytes_, maximum_bytes, alignof(char));
  }

  template <Allocator Memory>
  void PathIndexStorage<Memory>::reset() noexcept {
    count = 0;
    bytes_used = 0;
    truncated = false;
    failure = PathBuildFailure::none;
    published.store(0, std::memory_order_relaxed);
    complete.store(false, std::memory_order_relaxed);
    cancelled.store(false, std::memory_order_relaxed);
  }

  template <Allocator Memory>
  bool PathIndexStorage<Memory>::append(std::string_view relative, PathKind kind) noexcept {
    if (count == maximum_entries || relative.size() > maximum_bytes - bytes_used) {
      truncated = true;
      return false;
    }

    std::copy(relative.begin(), relative.end(), bytes_ + bytes_used);
    entries_[count++] = {.offset = static_cast<std::uint32_t>(bytes_used), .length = static_cast<std::uint16_t>(relative.size()), .kind = kind};
    bytes_used += relative.size();
    if (count % publication_batch == 0) {
      published.store(count, std::memory_order_release);
    }

    return true;
  }

  template <Allocator Memory>
  const IndexedPath& PathIndexStorage<Memory>::entry(std::size_t index) const noexcept {
    return entries_[index];
  }

  template <Allocator Memory>
  std::string_view PathIndexStorage<Memory>::path(const IndexedPath& entry) const noexcept {
    return {bytes_ + entry.offset, entry.length};
  }

  template <Allocator Memory>
  void PathIndexStorage<Memory>::finish() noexcept {
    published.store(count, std::memory_order_release);
    complete.store(true, std::memory_order_release);
  }

  template class PathIndexStorage<SystemAllocator>;
  template class PathIndexStorage<ConcurrentMemory>;

  PathIndexBuilder::PathIndexBuilder(tbc::mut_a<ConcurrentMemory> memory, tbc::mut_a<PathIndexStorage<ConcurrentMemory>> storage)
      : memory_(memory),
        storage_(storage) {}

  void PathIndexBuilder::build(const char* root) noexcept {
    TELAR_TRACE("paths.build");
    try {
      FileDescriptor directory{::open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
      if (!directory) {
        storage_.failure = PathBuildFailure::unreadable;
      } else {
        if (insideGit(root)) {
          tracked(root);
        }

        if (storage_.count == 0 && !storage_.cancelled.load(std::memory_order_relaxed)) {
          walk(directory.get());
        }
      }
    } catch (const std::bad_alloc&) {
      storage_.failure = PathBuildFailure::allocation;
    } catch (...) {
      storage_.truncated = true;
    }

    storage_.finish();
  }

  bool PathIndexBuilder::acceptable(std::string_view relative) noexcept {
    try {
      DisplayText16<1024, false>::validate(relative);
      return !relative.empty();
    } catch (const EncodingError&) {
      return false;
    }
  }

  bool PathIndexBuilder::insideGit(std::string_view path) noexcept {
    ds::Array<char, 4102> marker;

    while (!path.empty() && path.ends_with('/')) {
      path.remove_suffix(1);
    }

    for (;;) {
      if (path.size() + 6 > marker.size()) {
        return false;
      }

      std::copy(path.begin(), path.end(), marker.dataMut());
      std::memcpy(marker.dataMut() + path.size(), "/.git", 6);
      if (::access(marker.data(), F_OK) == 0) {
        return true;
      }

      const auto parent = path.rfind('/');
      if (parent == std::string_view::npos) {
        return false;
      }

      path = path.substr(0, parent);
    }
  }

  bool PathIndexBuilder::appendTracked(std::string_view relative, tbc::mut_a<Directories> directories) {
    if (!acceptable(relative)) {
      return true;
    }

    for (auto separator = relative.find('/'); separator != std::string_view::npos; separator = relative.find('/', separator + 1)) {
      const auto directory = relative.substr(0, separator + 1);
      if (directories.contains(directory)) {
        continue;
      }

      if (!storage_.append(directory, PathKind::directory)) {
        return false;
      }

      static_cast<void>(directories.insert(storage_.path(storage_.entry(storage_.count - 1)), true));
    }

    return storage_.append(relative, PathKind::file);
  }

  void PathIndexBuilder::tracked(const char* root) {
    try {
      const auto configuration_deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
      GitRepository git{memory_, root, configuration_deadline, storage_.cancelled};
      Directories directories{memory_};
      ds::Array<char, 1024> relative;
      std::size_t length = 0;
      bool oversized = false;

      git.stream({"ls-files", "-z", "--cached", "--others", "--exclude-standard"}, [&](std::span<const Byte> bytes) {
        for (const auto byte : bytes) {
          if (storage_.cancelled.load(std::memory_order_relaxed)) {
            return false;
          }

          if (byte == 0) {
            if (!oversized && !appendTracked({relative.data(), length}, directories)) {
              return false;
            }

            length = 0;
            oversized = false;
          } else if (length < relative.size()) {
            relative.atMut(length++) = static_cast<char>(byte);
          } else {
            oversized = true;
          }
        }

        return true;
      });
    } catch (const SystemError&) {
    } catch (const RequestError&) {
    }
  }

  FileDescriptor PathIndexBuilder::openRelative(int root, std::string_view relative) {
    FileDescriptor current{::fcntl(root, F_DUPFD_CLOEXEC, 3)};

    while (current && !relative.empty()) {
      const auto separator = relative.find('/');
      const auto name = relative.substr(0, separator);
      ds::Array<char, NAME_MAX + 1> component{};

      if (name.empty() || name.size() > NAME_MAX || name == "..") {
        return FileDescriptor{};
      }

      std::copy(name.begin(), name.end(), component.dataMut());
      current.reset(::openat(current.get(), component.data(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
      if (separator == std::string_view::npos) {
        break;
      }

      relative.remove_prefix(separator + 1);
    }

    return current;
  }

  void PathIndexBuilder::walk(int root) {
    list(root, {});
    for (std::size_t index = 0; index < storage_.count; ++index) {
      if (storage_.cancelled.load(std::memory_order_relaxed) || storage_.truncated) {
        return;
      }

      const auto& entry = storage_.entry(index);
      if (entry.kind != PathKind::directory) {
        continue;
      }

      const auto relative = storage_.path(entry);
      auto child = openRelative(root, relative);
      if (child) {
        list(child.get(), relative);
      }
    }
  }

  void PathIndexBuilder::list(int directory, std::string_view prefix) {
    FileDescriptor copy{::fcntl(directory, F_DUPFD_CLOEXEC, 3)};
    std::unique_ptr<DIR, decltype(&::closedir)> stream{::fdopendir(copy.get()), ::closedir};
    if (!stream) {
      return;
    }

    copy.release();
    while (const auto* entry = ::readdir(stream.get())) {
      if (storage_.cancelled.load(std::memory_order_relaxed)) {
        return;
      }

      const std::string_view name{entry->d_name};
      if (name.starts_with('.')) {
        continue;
      }

      struct stat status{};
      if (::fstatat(directory, entry->d_name, &status, AT_SYMLINK_NOFOLLOW) != 0) {
        continue;
      }

      const bool child_directory = S_ISDIR(status.st_mode);
      if (child_directory && (name == "node_modules" || name == "zig-out" || name == "target" || name == "__pycache__")) {
        continue;
      }

      ds::Array<char, 1024> relative;
      const auto length = prefix.size() + name.size() + static_cast<std::size_t>(child_directory);
      if (length > relative.size()) {
        continue;
      }

      std::copy(prefix.begin(), prefix.end(), relative.dataMut());
      std::copy(name.begin(), name.end(), relative.dataMut() + prefix.size());
      if (child_directory) {
        relative.atMut(length - 1) = '/';
      }

      const std::string_view value{relative.data(), length};
      if (acceptable(value) && !storage_.append(value, child_directory ? PathKind::directory : PathKind::file)) {
        return;
      }
    }
  }

  PathIndex::PathIndex(ConcurrentMemory& memory)
      : root_(memory),
        storage_(memory),
        builder_(memory, storage_),
        matcher_(memory) {
    root_.reserve(4096);
  }

  void PathIndex::stop() noexcept {
    storage_.cancelled.store(true, std::memory_order_relaxed);
  }

  std::string_view PathIndex::root() const noexcept {
    return root_;
  }

  void PathIndex::reset(std::string_view root) {
    root_.assign(root);
    storage_.reset();
  }

  void PathIndex::build() noexcept {
    builder_.build(root_.data());
  }

  bool PathIndex::complete() const noexcept {
    return storage_.complete.load(std::memory_order_acquire);
  }

  bool PathIndex::canQueryInline(const FindPaths& request) const noexcept {
    constexpr std::size_t maximum_inline_entries = 256;
    constexpr std::size_t maximum_inline_steps = 16 * 1024;
    const auto query_length = std::max<std::size_t>(1, request.query.size());

    return complete() && !request.refresh && root_ == request.root && storage_.count <= maximum_inline_entries && storage_.bytes_used <= maximum_inline_steps / query_length;
  }

  std::string_view PathIndex::path(const IndexedPath& entry) const noexcept {
    return storage_.path(entry);
  }

  std::size_t PathIndex::depth(std::string_view path) noexcept {
    if (path.ends_with('/')) {
      path.remove_suffix(1);
    }

    return std::count(path.begin(), path.end(), '/');
  }

  bool PathIndex::better(const Candidate& left, const Candidate& right, bool browse) const noexcept {
    const auto& left_entry = storage_.entry(left.entry);
    const auto& right_entry = storage_.entry(right.entry);
    const auto left_path = path(left_entry);
    const auto right_path = path(right_entry);

    if (browse) {
      if (depth(left_path) != depth(right_path)) {
        return depth(left_path) < depth(right_path);
      }

      if (left_entry.kind != right_entry.kind) {
        return left_entry.kind == PathKind::directory;
      }
    } else {
      if (left.score != right.score) {
        return left.score > right.score;
      }

      if (left_path.size() != right_path.size()) {
        return left_path.size() < right_path.size();
      }
    }

    return left_path < right_path;
  }

  void OwnedPathQuery::assign(const FindPaths& request) {
    request_id = request.request_id;
    root.assign(request.root);
    query.assign(request.query);
    kind = request.kind;
    limit = request.limit;
  }

  FindPaths OwnedPathQuery::view() const noexcept {
    return FindPaths{.request_id = request_id, .root = root.view(), .query = query.view(), .kind = kind, .limit = limit};
  }

}
