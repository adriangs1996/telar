module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.paths.query_task;

import telar.platform.error;
import telar.runtime.workspaces.git_status;
import telar.sys.posix;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    // The longest relative path the index keeps, as a client is sent it.
    constexpr std::size_t relative_path_bytes = 1024;

    // The marker a repository's root holds, terminated.
    constexpr std::string_view git_marker = "/.git";

    // The path `git ls-files -z` is streaming, gathered a byte at a time; one longer than the index
    // keeps is passed over whole.
    class TrackedPath {
    public:
      // Takes the next byte; true when it ends a path to keep, which `path` then views.
      bool push(Byte byte) noexcept {
        if (byte != 0) {
          if (length_ < bytes_.size()) {
            bytes_.atMut(length_++) = static_cast<char>(byte);
          } else {
            oversized_ = true;
          }

          return false;
        }

        const bool kept = !oversized_;

        ended_ = std::exchange(length_, 0);
        oversized_ = false;
        return kept;
      }

      [[nodiscard]] std::string_view path() const noexcept {
        return std::string_view{bytes_.view().first(ended_)};
      }

      // Hands each path `bytes` completes to `append` until it refuses one or the build is
      // cancelled; whether to read on.
      template <typename Append>
      bool feed(std::span<const Byte> bytes, const std::atomic<bool>& cancelled, Append& append) {
        return std::ranges::all_of(bytes, [&](Byte byte) {
          return !cancelled.load(std::memory_order_relaxed) && (!push(byte) || append(path()));
        });
      }

    private:
      ds::Array<char, relative_path_bytes> bytes_{};
      std::size_t length_ = 0;
      std::size_t ended_ = 0;
      bool oversized_ = false;
    };

    // A path `git ls-files --stage` lists, and whether it is a repository inside the one listed.
    struct ListedPath {
      std::string_view path;
      bool repository = false;
    };

    // A record of `git ls-files --stage`: "<mode> <object> <stage>\t<path>" for a path the index
    // holds, the path alone for one it does not. A repository inside is a submodule, of mode
    // 160000, or a directory the index does not hold, which git ends with its '/'.
    ListedPath listedPath(std::string_view record) noexcept {
      constexpr std::size_t mode_digits = 6;
      constexpr std::string_view submodule_mode = "160000";
      const auto tab = record.find('\t');

      if (tab == std::string_view::npos || tab <= mode_digits + 2 || record[mode_digits] != ' ' || record[tab - 2] != ' ') {
        return {.path = record, .repository = record.ends_with('/')};
      }

      // The mode, before the tab found inside the record, and the path after it.
      auto mode = record;
      auto path = record;

      mode.remove_suffix(record.size() - mode_digits);
      if (!std::ranges::all_of(mode, [](char digit) {
            return digit >= '0' && digit <= '7';
          })) {
        return {.path = record, .repository = record.ends_with('/')};
      }

      path.remove_prefix(tab + 1);
      return {.path = path, .repository = record.starts_with(submodule_mode)};
    }

    // Storage the allocator handed out for `count` values; empty when it had none.
    template <typename Value, Allocator Memory>
    std::span<Value> allocateValues(Memory& memory, std::size_t count) {
      auto* const values = static_cast<Value*>(memory.allocate(count * sizeof(Value), alignof(Value)));
      if (values == nullptr) {
        return {};
      }

      // The allocator hands out raw storage of the size it was asked for.
#pragma clang unsafe_buffer_usage begin
      return std::span<Value>{values, count};
#pragma clang unsafe_buffer_usage end
    }

  }

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

    ds::Array<std::uint16_t, maximum_needle> first_matches; // NOLINT(cppcoreguidelines-pro-type-member-init): scored for every indexed path, and only the query's first matches are written and read
    if (!firstMatches(path, query, first_matches, positions)) {
      return ds::none;
    }

    if (path.size() > maximum_path) {
      return minimum_score / 2;
    }

    if (path.size() == query.size()) {
      return std::numeric_limits<std::int32_t>::max() / 2;
    }

    ds::Array<std::int32_t, maximum_path> bonuses; // NOLINT(cppcoreguidelines-pro-type-member-init): scored for every indexed path, and only the path's bonuses are written and read
    char previous = '/';
    // A letter matched in the file's own name counts more than one in a folder above it: a
    // search that starts with a folder's name still finds first the files named so.
    const auto name_start = path.find_last_of('/') + 1;

    for (std::size_t index = 0; index < path.size(); ++index) {
      bonuses.atMut(index) = bonus(previous, path[index]) + (index >= name_start ? name_bonus : 0);
      previous = path[index];
    }

    const bool retain_rows = !positions.empty();

    align(path, query, first_matches, bonuses, retain_rows);
    if (retain_rows) {
      trace(path.size(), first_matches.view().first(query.size()), positions);
    }

    return row(retain_rows ? query.size() - 1 : (query.size() - 1) % 2, true)[path.size() - 1];
  }

  template <Allocator Memory>
  bool FuzzyMatch<Memory>::firstMatches(std::string_view path, std::string_view query, ds::Array<std::uint16_t, maximum_needle>& matches, std::span<std::uint16_t> positions) noexcept {
    std::size_t offset = 0;

    for (std::size_t matched = 0; matched < query.size(); ++matched) {
      const char wanted = lower(query[matched]);

      while (offset < path.size() && lower(path[offset]) != wanted) {
        ++offset;
      }

      if (offset == path.size()) {
        return false;
      }

      matches.atMut(matched) = static_cast<std::uint16_t>(offset);
      if (!positions.empty()) {
        positions[matched] = matches[matched];
      }

      ++offset;
    }

    return true;
  }

  template <Allocator Memory>
  void FuzzyMatch<Memory>::align(std::string_view path, std::string_view query, const ds::Array<std::uint16_t, maximum_needle>& first_matches, const ds::Array<std::int32_t, maximum_path>& bonuses, bool retain_rows) noexcept {
    for (std::size_t index = 0; index < query.size(); ++index) {
      const auto current = retain_rows ? index : index % 2;
      std::size_t preceding = 0;

      if (retain_rows) {
        preceding = index == 0 ? 0 : index - 1;
      } else {
        preceding = 1 - current;
      }

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
  }

  template <Allocator Memory>
  void FuzzyMatch<Memory>::trace(std::size_t path_size, std::span<const std::uint16_t> first_matches, std::span<std::uint16_t> positions) noexcept {
    bool required = false;
    std::size_t column = path_size;

    for (std::size_t index = first_matches.size(); index != 0;) {
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
    // A match that starts a path segment counts most, then one after a separator, a camel-case
    // hump and an extension.
    constexpr int segment_bonus = 900;
    constexpr int separator_bonus = 800;
    constexpr int camel_bonus = 700;
    constexpr int extension_bonus = 600;
    const char folded = lower(value);
    if ((folded < 'a' || folded > 'z') && (value < '0' || value > '9')) {
      return 0;
    }

    switch (previous) {
    case '/':
      return segment_bonus;
    case '-':
    case '_':
    case ' ':
      return separator_bonus;
    case '.':
      return extension_bonus;
    default:
      return previous >= 'a' && previous <= 'z' && value >= 'A' && value <= 'Z' ? camel_bonus : 0;
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
      : memory_(memory),
        bytes_(allocateValues<char>(memory_, maximum_bytes)),
        changes_(memory) {
    if (bytes_.empty()) {
      throw std::bad_alloc{};
    }

    entries_ = allocateValues<IndexedPath>(memory_, maximum_entries);
    if (entries_.empty()) {
      memory_.deallocate(bytes_.data(), maximum_bytes, alignof(char));
      throw std::bad_alloc{};
    }
  }

  template <Allocator Memory>
  PathIndexStorage<Memory>::~PathIndexStorage() {
    memory_.deallocate(entries_.data(), entry_bytes, alignof(IndexedPath));
    memory_.deallocate(bytes_.data(), maximum_bytes, alignof(char));
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
    changes_published.store(false, std::memory_order_relaxed);
    changes_.clear();
  }

  template <Allocator Memory>
  bool PathIndexStorage<Memory>::append(std::string_view relative, PathKind kind) noexcept {
    if (count == maximum_entries || relative.size() > maximum_bytes - bytes_used) {
      truncated = true;
      return false;
    }

    std::ranges::copy(relative, bytes_.subspan(bytes_used).begin());
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
    return std::string_view{bytes_.subspan(entry.offset, entry.length)};
  }

  template <Allocator Memory>
  void PathIndexStorage<Memory>::finish() noexcept {
    published.store(count, std::memory_order_release);
    complete.store(true, std::memory_order_release);
  }

  template <Allocator Memory>
  bool PathIndexStorage<Memory>::noteChange(std::string_view relative, PathChange change) {
    if (changes_.size() == maximum_changes) {
      return false;
    }

    static_cast<void>(changes_.assign(ds::String<Memory>{memory_, relative}, change));
    return true;
  }

  template <Allocator Memory>
  void PathIndexStorage<Memory>::publishChanges() noexcept {
    changes_published.store(true, std::memory_order_release);
  }

  template <Allocator Memory>
  PathChange PathIndexStorage<Memory>::change(std::string_view relative) const noexcept {
    if (!changes_published.load(std::memory_order_acquire)) {
      return PathChange::none;
    }

    const auto* const found = changes_.find(relative);

    return found == nullptr ? PathChange::none : *found;
  }

  PathChange pathChange(char staged, char unstaged) noexcept {
    if (staged == '?') {
      return PathChange::untracked;
    }

    if (staged == 'U' || unstaged == 'U' || (staged == 'A' && unstaged == 'A') || (staged == 'D' && unstaged == 'D')) {
      return PathChange::conflicted;
    }

    if (staged == 'D' || unstaged == 'D') {
      return PathChange::deleted;
    }

    if (staged == 'A') {
      return PathChange::added;
    }

    if (staged == 'R' || unstaged == 'R') {
      return PathChange::renamed;
    }

    const auto changed = [](char state) {
      return state == 'M' || state == 'T' || state == 'C';
    };

    return changed(staged) || changed(unstaged) ? PathChange::modified : PathChange::none;
  }

  template class PathIndexStorage<SystemAllocator>;
  template class PathIndexStorage<ConcurrentMemory>;

  PathIndexBuilder::PathIndexBuilder(tbc::mut_a<ConcurrentMemory> memory, tbc::mut_a<PathIndexStorage<ConcurrentMemory>> storage)
      : memory_(memory),
        storage_(storage) {}

  void PathIndexBuilder::build(const char* root) noexcept {
    TELAR_TRACE("paths.build");
    try {
      const FileDescriptor directory{::open(root, combineFlags(O_RDONLY, O_DIRECTORY, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
      if (!directory) {
        storage_.failure = PathBuildFailure::unreadable;
      } else {
        const bool repository = insideGit(root);

        if (repository) {
          tracked(root);
        }

        if (storage_.count == 0 && !storage_.cancelled.load(std::memory_order_relaxed)) {
          walk(directory.get());
        }

        // After the paths, which a search shows as they come: what git says of them follows.
        if (repository && !storage_.cancelled.load(std::memory_order_relaxed)) {
          changes(root);
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
      DisplayText16<relative_path_bytes, false>::validate(relative);
      return !relative.empty();
    } catch (const EncodingError&) {
      return false;
    }
  }

  bool PathIndexBuilder::insideGit(std::string_view path) noexcept {
    ds::Array<char, OwnedPathQuery::root_bytes + git_marker.size() + 1> marker{};

    while (!path.empty() && path.ends_with('/')) {
      path.remove_suffix(1);
    }

    for (;;) {
      if (path.size() + git_marker.size() + 1 > marker.size()) {
        return false;
      }

      const auto written = marker.viewMut();
      const auto after = std::ranges::copy(path, written.begin()).out;

      *std::ranges::copy(git_marker, after).out = '\0';
      if (::access(marker.data(), F_OK) == 0) {
        return true;
      }

      const auto parent = path.rfind('/');
      if (parent == std::string_view::npos) {
        return false;
      }

      path.remove_suffix(path.size() - parent);
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

    // A path that ends with '/' is a directory, appended above as the last of them.
    return relative.ends_with('/') || storage_.append(relative, PathKind::file);
  }

  void PathIndexBuilder::tracked(const char* root) {
    Directories directories{memory_};
    Repositories repositories{memory_};
    std::string_view top{root};

    while (top.ends_with('/')) {
      top.remove_suffix(1);
    }

    listTracked(root, {}, directories, repositories);
    for (std::size_t index = 0; index < repositories.size(); ++index) {
      if (storage_.cancelled.load(std::memory_order_relaxed) || storage_.truncated) {
        return;
      }

      // More than a search should wait for: the rest are not listed, and the list says so.
      if (index == most_nested_repositories) {
        storage_.truncated = true;
        return;
      }

      // The repository's directory, and its marker after it, terminated.
      const auto prefix = repositories[index];
      ds::Array<char, OwnedPathQuery::root_bytes + relative_path_bytes + git_marker.size() + 1> path{};
      const auto directory_size = top.size() + prefix.size();

      if (directory_size + git_marker.size() >= path.size()) {
        continue;
      }

      const auto written = path.viewMut();
      auto end = std::ranges::copy(top, written.begin()).out;

      *end++ = '/';
      end = std::ranges::copy(prefix.substr(0, prefix.size() - 1), end).out;
      *std::ranges::copy(git_marker, end).out = '\0';

      // A submodule that is not checked out is an empty directory of the outer repository.
      if (::access(path.data(), F_OK) == 0) {
        listTracked(std::string_view{path.data(), directory_size}, prefix, directories, repositories);
      }
    }
  }

  void PathIndexBuilder::listTracked(std::string_view directory, std::string_view prefix, tbc::mut_a<Directories> directories, tbc::mut_a<Repositories> repositories) { // NOLINT(bugprone-easily-swappable-parameters): where the repository is, then what its paths are below the root, as the caller walks them
    try {
      const auto configuration_deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
      GitRepository git{memory_, directory, configuration_deadline, storage_.cancelled};
      TrackedPath current;
      ds::Array<char, relative_path_bytes> joined{};

      const auto append = [&](std::string_view record) {
        const auto listed = listedPath(record);
        // A submodule's path comes without the '/' that makes it a directory here.
        const bool closed = listed.repository && !listed.path.ends_with('/');
        const auto size = prefix.size() + listed.path.size() + static_cast<std::size_t>(closed);

        // Passed over, as the reader passes over a path longer than the index keeps.
        if (size > joined.size()) {
          return true;
        }

        const auto written = joined.viewMut();
        const auto end = std::ranges::copy(listed.path, std::ranges::copy(prefix, written.begin()).out).out;

        if (closed) {
          *end = '/';
        }

        const std::string_view relative{joined.data(), size};

        // A path in conflict comes once for each side, one after another.
        if (storage_.count > 0 && storage_.path(storage_.entry(storage_.count - 1)) == relative) {
          return true;
        }

        const auto before = storage_.count;

        if (!appendTracked(relative, directories)) {
          return false;
        }

        // A repository's directory is the last entry its path appended.
        if (listed.repository && storage_.count != before) {
          repositories.push(storage_.path(storage_.entry(storage_.count - 1)));
        }

        return true;
      };

      git.stream({"ls-files", "-z", "--stage", "--cached", "--others", "--exclude-standard"}, [&](std::span<const Byte> bytes) {
        return current.feed(bytes, storage_.cancelled, append);
      });
    } catch (const SystemError&) {  // NOLINT(bugprone-empty-catch): without git the walk lists the directory instead
    } catch (const RequestError&) { // NOLINT(bugprone-empty-catch): without git the walk lists the directory instead
    }
  }

  void PathIndexBuilder::changes(const char* root) {
    try {
      const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
      GitRepository git{memory_, root, deadline, storage_.cancelled};
      // git names a path from the repository's top, the index from `root`: the part between.
      const ds::String<ConcurrentMemory> prefix{memory_, git.run({"rev-parse", "--show-prefix"})};
      TrackedPath current;
      // Each record is two letters, what the index and the work tree hold, a space and a path.
      constexpr std::size_t record_head = 3;
      const auto note = [&](std::string_view record) {
        if (record.size() <= record_head || !record.substr(record_head).starts_with(prefix.view())) {
          return true;
        }

        const auto change = pathChange(record[0], record[1]);

        return change == PathChange::none || storage_.noteChange(record.substr(record_head + prefix.size()), change);
      };

      git.stream({"status", "--porcelain=v1", "-z", "--no-renames", "--untracked-files=all", "--", "."}, [&](std::span<const Byte> bytes) {
        return current.feed(bytes, storage_.cancelled, note);
      });
    } catch (const SystemError&) {    // NOLINT(bugprone-empty-catch): without git's answer every path shows as committed
    } catch (const RequestError&) {   // NOLINT(bugprone-empty-catch): without git's answer every path shows as committed
    } catch (const std::bad_alloc&) { // NOLINT(bugprone-empty-catch): the changes noted before are kept, the paths are whole
    }

    storage_.publishChanges();
  }

  FileDescriptor PathIndexBuilder::openRelative(int root, std::string_view relative) {
    FileDescriptor current{::fcntl(root, F_DUPFD_CLOEXEC, 3)}; // NOLINT(cppcoreguidelines-pro-type-vararg): fcntl's C signature is variadic

    while (current && !relative.empty()) {
      const auto separator = relative.find('/');
      const auto name = relative.substr(0, separator);
      ds::Array<char, NAME_MAX + 1> component{};

      if (name.empty() || name.size() > NAME_MAX || name == "..") {
        current.reset();
        return current;
      }

      std::ranges::copy(name, component.viewMut().begin());
      current.reset(::openat(current.get(), component.data(), combineFlags(O_RDONLY, O_DIRECTORY, O_NOFOLLOW, O_CLOEXEC))); // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
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
      const auto child = openRelative(root, relative);
      if (child) {
        list(child.get(), relative);
      }
    }
  }

  void PathIndexBuilder::list(int directory, std::string_view prefix) {
    FileDescriptor copy{::fcntl(directory, F_DUPFD_CLOEXEC, 3)}; // NOLINT(cppcoreguidelines-pro-type-vararg): fcntl's C signature is variadic
    std::unique_ptr<DIR, decltype(&::closedir)> stream{::fdopendir(copy.get()), ::closedir};
    if (!stream) {
      return;
    }

    copy.release();
    while (const auto* entry = ::readdir(stream.get())) { // NOLINT(concurrency-mt-unsafe): readdir is unsafe only on a stream that another thread reads too, and this stream is the call's own
      if (storage_.cancelled.load(std::memory_order_relaxed)) {
        return;
      }

      const auto* const terminated = std::data(entry->d_name);
      const std::string_view name{terminated};
      if (name.starts_with('.')) {
        continue;
      }

      struct stat status{};
      if (::fstatat(directory, terminated, &status, AT_SYMLINK_NOFOLLOW) != 0) {
        continue;
      }

      const bool child_directory = S_ISDIR(status.st_mode);
      if (child_directory && (name == "node_modules" || name == "zig-out" || name == "target" || name == "__pycache__")) {
        continue;
      }

      ds::Array<char, relative_path_bytes> relative; // NOLINT(cppcoreguidelines-pro-type-member-init): built for every entry the walk lists, and only the bytes written are read
      const auto length = prefix.size() + name.size() + static_cast<std::size_t>(child_directory);
      if (length > relative.size()) {
        continue;
      }

      std::ranges::copy(prefix, relative.viewMut().begin());
      std::ranges::copy(name, relative.viewMut().subspan(prefix.size()).begin());
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
    root_.reserve(OwnedPathQuery::root_bytes);
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
    constexpr std::size_t maximum_inline_steps = std::size_t{16} * 1024;
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

    return static_cast<std::size_t>(std::ranges::count(path, '/'));
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
