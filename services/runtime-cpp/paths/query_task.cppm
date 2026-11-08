module;
#include "tbc/view.hpp"
#include "telar_platform/trace_macro.hpp"
#include <cstdlib>
#include <new>
#include <cstdio>
#include <unistd.h>

#include <cstdint>


#include <cassert>
#include <cstring>
#include <cstddef>
#include <cerrno>
#include <sys/types.h>
#include <limits.h>
#include <poll.h>
#include <sys/wait.h>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>

export module telar.runtime.paths.query_task;

import std;

export import telar.runtime.platform.git_status;


export import telar.runtime.transport.connection;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;

// Interface: paths/fuzzy_match.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class FuzzyMatch {
public:
  inline explicit FuzzyMatch(Memory &memory)
      : matrix_(AllocatorRef<std::int32_t, Memory>{memory}) {
    matrix_.resize(2 * maximum_needle * maximum_path);
  }

  inline std::optional<std::int32_t> score(std::string_view path, std::string_view query, std::span<std::uint16_t> positions = {}) {
    if (query.empty()) {
      return 0;
    }
    if (query.size() > maximum_needle || query.size() > path.size()) {
      return std::nullopt;
    }
    std::array<std::uint16_t, maximum_needle> first_matches;
    std::size_t offset = 0;
    for (std::size_t matched = 0; matched < query.size(); ++matched) {
      const char wanted = lower(query[matched]);
      while (offset < path.size() && lower(path[offset]) != wanted) {
        ++offset;
      }
      if (offset == path.size()) {
        return std::nullopt;
      }

      first_matches[matched] = static_cast<std::uint16_t>(offset);
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

    std::array<std::int32_t, maximum_path> bonuses;
    char previous = '/';
    for (std::size_t index = 0; index < path.size(); ++index) {
      bonuses[index] = bonus(previous, path[index]);
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
          cell = static_cast<int>(column) * leading_gap + bonuses[column];
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

private:
  inline static char lower(char value) noexcept {
    return value >= 'A' && value <= 'Z' ? static_cast<char>(value + ('a' - 'A')) : value;
  }

  inline static std::int32_t plus(std::int32_t value, int increment) noexcept {
    return value == minimum_score ? minimum_score : value + increment;
  }

  inline static int bonus(char previous, char value) noexcept {
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

  inline std::span<std::int32_t> row(std::size_t index, bool best) noexcept {
    return std::span{matrix_}.subspan((index * 2 + static_cast<unsigned>(best)) * maximum_path, maximum_path);
  }

  static constexpr std::size_t maximum_path = 1024;
  static constexpr std::size_t maximum_needle = 64;
  static constexpr int consecutive_score = 1000;
  static constexpr int leading_gap = -5;
  static constexpr int inner_gap = -10;
  static constexpr int trailing_gap = -5;
  static constexpr auto minimum_score = std::numeric_limits<std::int32_t>::min();
  Vector<std::int32_t, Memory> matrix_;
};

}
}

// Interface: paths/index_storage.cppm
export {
namespace telar::runtime {

struct IndexedPath {
  std::uint32_t offset;
  std::uint16_t length;
  PathKind kind;
};

enum class PathBuildFailure {
  none,
  unreadable,
  allocation
};

template <Allocator Memory>
class PathIndexStorage {
public:
  static constexpr std::size_t maximum_entries = 512 * 1024;
  static constexpr std::size_t maximum_bytes = 32 * 1024 * 1024;

  inline explicit PathIndexStorage(Memory &memory)
      : memory_(memory) {
    bytes_ = static_cast<char *>(memory_.allocate(maximum_bytes, alignof(char)));
    if (bytes_ == nullptr) {
      throw std::bad_alloc{};
    }

    entries_ = static_cast<IndexedPath *>(memory_.allocate(entry_bytes, alignof(IndexedPath)));
    if (entries_ == nullptr) {
      memory_.deallocate(bytes_, maximum_bytes, alignof(char));
      throw std::bad_alloc{};
    }
  }

  inline ~PathIndexStorage() {
    memory_.deallocate(entries_, entry_bytes, alignof(IndexedPath));
    memory_.deallocate(bytes_, maximum_bytes, alignof(char));
  }

  PathIndexStorage(const PathIndexStorage &) = delete;
  PathIndexStorage &operator=(const PathIndexStorage &) = delete;

  inline void reset() noexcept {
    count = 0;
    bytes_used = 0;
    truncated = false;
    failure = PathBuildFailure::none;
    published.store(0, std::memory_order_relaxed);
    complete.store(false, std::memory_order_relaxed);
    cancelled.store(false, std::memory_order_relaxed);
  }

  inline bool append(std::string_view relative, PathKind kind) noexcept {
    if (count == maximum_entries || relative.size() > maximum_bytes - bytes_used) {
      truncated = true;
      return false;
    }

    std::copy(relative.begin(), relative.end(), bytes_ + bytes_used);
    entries_[count++] = {static_cast<std::uint32_t>(bytes_used), static_cast<std::uint16_t>(relative.size()), kind};
    bytes_used += relative.size();
    if (count % publication_batch == 0) {
      published.store(count, std::memory_order_release);
    }
    return true;
  }

  inline const IndexedPath &entry(std::size_t index) const noexcept {
    return entries_[index];
  }

  inline std::string_view path(const IndexedPath &entry) const noexcept {
    return {bytes_ + entry.offset, entry.length};
  }

  inline void finish() noexcept {
    published.store(count, std::memory_order_release);
    complete.store(true, std::memory_order_release);
  }

  // One builder appends to fixed storage; readers access only the released prefix.
  std::atomic<std::size_t> published{0};
  std::atomic<bool> complete{false};
  std::atomic<bool> cancelled{false};
  std::size_t count = 0;
  std::size_t bytes_used = 0;
  bool truncated = false;
  PathBuildFailure failure = PathBuildFailure::none;

private:
  static constexpr std::size_t entry_bytes = maximum_entries * sizeof(IndexedPath);
  static constexpr std::size_t publication_batch = 1024;
  Memory &memory_;
  char *bytes_;
  IndexedPath *entries_;
};

}
}

// Interface: paths/index_builder.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class PathIndexBuilder {
public:
  // Builds into the storage it is given; the directories it tracks view it, region `a`.
  inline explicit PathIndexBuilder(tbc::view<Memory &, tbc::lt::a> memory, tbc::view<PathIndexStorage<Memory> &, tbc::lt::a> storage)
      : memory_(memory),
        storage_(storage) {}

  inline void build(const char *root) noexcept {
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
    } catch (const std::bad_alloc &) {
      storage_.failure = PathBuildFailure::allocation;
    } catch (...) {
      storage_.truncated = true;
    }

    storage_.finish();
  }

private:
  using Directories = std::unordered_set<std::string_view, std::hash<std::string_view>, std::equal_to<std::string_view>, AllocatorRef<std::string_view, Memory>>;

  inline static bool acceptable(std::string_view relative) noexcept {
    try {
      DisplayText16<1024, false>::validate(relative);
      return !relative.empty();
    } catch (const EncodingError &) {
      return false;
    }
  }

  inline static bool insideGit(std::string_view path) noexcept {
    std::array<char, 4102> marker;
    while (!path.empty() && path.ends_with('/')) {
      path.remove_suffix(1);
    }
    for (;;) {
      if (path.size() + 6 > marker.size()) {
        return false;
      }

      std::copy(path.begin(), path.end(), marker.begin());
      std::memcpy(marker.data() + path.size(), "/.git", 6);
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

  inline bool appendTracked(std::string_view relative, tbc::view<Directories &, tbc::lt::a> directories) {
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
      directories.insert(storage_.path(storage_.entry(storage_.count - 1)));
    }

    return storage_.append(relative, PathKind::file);
  }

  inline void tracked(const char *root) {
    try {
      const auto configuration_deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
      GitRepository git{memory_, root, configuration_deadline, storage_.cancelled};
      Directories directories{0, std::hash<std::string_view>{}, std::equal_to<std::string_view>{}, AllocatorRef<std::string_view, Memory>{memory_}};
      std::array<char, 1024> relative;
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
            relative[length++] = static_cast<char>(byte);
          } else {
            oversized = true;
          }
        }

        return true;
      });
    } catch (const SystemError &) {
    } catch (const RequestError &) {
    }
  }

  inline static FileDescriptor openRelative(int root, std::string_view relative) {
    FileDescriptor current{::fcntl(root, F_DUPFD_CLOEXEC, 3)};
    while (current && !relative.empty()) {
      const auto separator = relative.find('/');
      const auto name = relative.substr(0, separator);
      std::array<char, NAME_MAX + 1> component{};
      if (name.empty() || name.size() > NAME_MAX || name == "..") {
        return FileDescriptor{};
      }
      std::copy(name.begin(), name.end(), component.begin());
      current.reset(::openat(current.get(), component.data(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
      if (separator == std::string_view::npos) {
        break;
      }
      relative.remove_prefix(separator + 1);
    }

    return current;
  }

  inline void walk(int root) {
    list(root, {});
    for (std::size_t index = 0; index < storage_.count; ++index) {
      if (storage_.cancelled.load(std::memory_order_relaxed) || storage_.truncated) {
        return;
      }
      const auto &entry = storage_.entry(index);
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

  inline void list(int directory, std::string_view prefix) {
    FileDescriptor copy{::fcntl(directory, F_DUPFD_CLOEXEC, 3)};
    std::unique_ptr<DIR, decltype(&::closedir)> stream{::fdopendir(copy.get()), ::closedir};
    if (!stream) {
      return;
    }
    copy.release();
    while (const auto *entry = ::readdir(stream.get())) {
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

      std::array<char, 1024> relative;
      const auto length = prefix.size() + name.size() + child_directory;
      if (length > relative.size()) {
        continue;
      }
      std::copy(prefix.begin(), prefix.end(), relative.begin());
      std::copy(name.begin(), name.end(), relative.begin() + prefix.size());
      if (child_directory) {
        relative[length - 1] = '/';
      }

      const std::string_view value{relative.data(), length};
      if (acceptable(value) && !storage_.append(value, child_directory ? PathKind::directory : PathKind::file)) {
        return;
      }
    }
  }

  tbc::view<Memory &, tbc::lt::a> memory_;
  tbc::view<PathIndexStorage<Memory> &, tbc::lt::a> storage_;
};

}
}

// Interface: paths/path_index.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class PathIndex {
public:
  inline explicit PathIndex(Memory &memory)
      : root_(AllocatorRef<char, Memory>{memory}),
        storage_(memory),
        builder_(memory, storage_),
        matcher_(memory) {
    root_.reserve(4096);
  }

  inline void stop() noexcept {
    storage_.cancelled.store(true, std::memory_order_relaxed);
  }

  inline std::string_view root() const noexcept {
    return root_;
  }

  inline void reset(std::string_view root) {
    root_.assign(root);
    storage_.reset();
  }

  inline void build() noexcept {
    builder_.build(root_.c_str());
  }

  inline bool complete() const noexcept {
    return storage_.complete.load(std::memory_order_acquire);
  }

  inline bool canQueryInline(const FindPaths &request) const noexcept {
    constexpr std::size_t maximum_inline_entries = 256;
    constexpr std::size_t maximum_inline_steps = 16 * 1024;
    const auto query_length = std::max<std::size_t>(1, request.query.size());
    return complete() && !request.refresh && root_ == request.root && storage_.count <= maximum_inline_entries && storage_.bytes_used <= maximum_inline_steps / query_length;
  }

  template <typename Reply>
  inline void query(const FindPaths &request, Reply &reply) {
    if (!complete() || root_ != request.root || request.refresh) {
      reset(request.root);
      build();
    }
    queryPublished(request, reply);
  }

  template <typename Reply>
  inline bool queryPublished(const FindPaths &request, Reply &reply) {
    TELAR_TRACE("paths.query");
    const bool complete = this->complete();
    const auto published = storage_.published.load(std::memory_order_acquire);
    if (complete && storage_.failure == PathBuildFailure::unreadable) {
      throw RequestError{FailureCode::permission_denied, "Path root is not readable"};
    }
    if (complete && storage_.failure == PathBuildFailure::allocation) {
      throw std::bad_alloc{};
    }
    std::array<Candidate, 50> ranked;
    std::size_t count = 0;
    for (std::size_t index = 0; index < published; ++index) {
      const auto &entry = storage_.entry(index);
      if ((request.kind == PathKindFilter::files && entry.kind != PathKind::file) || (request.kind == PathKindFilter::directories && entry.kind != PathKind::directory)) {
        continue;
      }
      const auto score = matcher_.score(path(entry), request.query);
      if (!score) {
        continue;
      }
      const Candidate candidate{index, *score};
      std::size_t position = count;
      while (position != 0 && better(candidate, ranked[position - 1], request.query.empty())) {
        --position;
      }
      if (position >= request.limit) {
        continue;
      }
      const auto kept = std::min<std::size_t>(count, request.limit - 1);
      for (std::size_t moved = kept; moved > position; --moved) {
        ranked[moved] = ranked[moved - 1];
      }
      ranked[position] = candidate;
      count = kept + 1;
    }

    std::array<PathMatch, 50> matches;
    std::array<std::array<std::uint16_t, 64>, 50> positions;
    for (std::size_t index = 0; index < count; ++index) {
      const auto &entry = storage_.entry(ranked[index].entry);
      const auto value = path(entry);
      matcher_.score(value, request.query, positions[index]);
      matches[index] = {value, entry.kind, std::span{positions[index]}.first(request.query.size())};
    }

    reply.send(PathResults{request.request_id, root_, static_cast<std::uint32_t>(published), complete, complete && storage_.truncated, std::span{matches}.first(count)});
    return complete;
  }

private:
  struct Candidate {
    std::size_t entry;
    std::int32_t score;
  };

  inline std::string_view path(const IndexedPath &entry) const noexcept {
    return storage_.path(entry);
  }

  inline static std::size_t depth(std::string_view path) noexcept {
    if (path.ends_with('/')) {
      path.remove_suffix(1);
    }

    return std::count(path.begin(), path.end(), '/');
  }

  inline bool better(const Candidate &left, const Candidate &right, bool browse) const noexcept {
    const auto &left_entry = storage_.entry(left.entry);
    const auto &right_entry = storage_.entry(right.entry);
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

  String<Memory> root_;
  PathIndexStorage<Memory> storage_;
  // Builds into storage_.
  tbc::view<PathIndexBuilder<Memory>, tbc::lt::self> builder_;
  FuzzyMatch<Memory> matcher_;
};

}
}

// Interface: paths/query_task.cppm
export {
namespace telar::runtime {

template <typename Index, typename Memory>
concept PathSearchIndex = Allocator<Memory> && requires(Index &index, const FindPaths &request, EncodedReply<Memory> &reply) {
  { index.root() } noexcept -> std::same_as<std::string_view>;
  { index.reset(request.root) } -> std::same_as<void>;
  { index.build() } noexcept -> std::same_as<void>;
  { index.stop() } noexcept -> std::same_as<void>;
  { index.complete() } noexcept -> std::same_as<bool>;
  { index.canQueryInline(request) } noexcept -> std::same_as<bool>;
  { index.queryPublished(request, reply) } -> std::same_as<bool>;
};

struct OwnedPathQuery {
  inline void assign(const FindPaths &request) {
    request_id = request.request_id;
    root.assign(request.root);
    query.assign(request.query);
    kind = request.kind;
    limit = request.limit;
  }

  inline FindPaths view() const noexcept {
    return FindPaths{.request_id = request_id, .root = root.view(), .query = query.view(), .kind = kind, .limit = limit};
  }

  std::uint64_t request_id = 0;
  FixedText<4096> root;
  FixedText<64> query;
  PathKindFilter kind = PathKindFilter::any;
  std::uint16_t limit = 50;
};

template <Allocator Memory, typename Index = PathIndex<Memory>>
  requires PathSearchIndex<Index, Memory>
class PathQueryTask {
public:
  using Request = OwnedPathQuery;

  struct Result {
    bool complete;
    std::span<const Byte> payload;
  };

  inline explicit PathQueryTask(Memory &memory, Index &index)
      : index_(index),
        reply_(memory) {}

  inline void stop() noexcept {
    index_.stop();
  }

  inline Result observe(const Request &request) noexcept {
    try {
      const bool complete = index_.queryPublished(request.view(), reply_);
      return {complete, reply_.payload()};
    } catch (const RequestError &error) {
      reply_.send(RequestFailed{.request_id = request.request_id, .code = error.code(), .message = error.what()});
    } catch (...) {
      reply_.send(RequestFailed{.request_id = request.request_id, .code = FailureCode::resource_limit, .message = "Path query memory is unavailable"});
    }

    return {true, reply_.payload()};
  }

private:
  Index &index_;
  EncodedReply<Memory> reply_;
};

template <typename Index>
class PathBuildTask {
public:
  using Request = bool;
  using Result = bool;

  inline explicit PathBuildTask(Index &index)
      : index_(index) {}

  inline void stop() noexcept {
    index_.stop();
  }

  inline bool observe(bool) noexcept {
    index_.build();
    return true;
  }

private:
  Index &index_;
};

}
}
