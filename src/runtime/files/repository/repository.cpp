module telar.runtime.files.repository;

import std;
import telar.sys.posix;
import telar.platform.error;
import telar.platform.primitives;
import telar.runtime.files.entry;
import telar.runtime.transport.connection;
import telar.runtime.workspaces.git_status;
import telar.wire.files;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.base.ds;
import telar.base.text;
import telar.base.text.utf8;

namespace telar::runtime {

  namespace {

    using Clock = std::chrono::steady_clock;

    // A record is a path and what git writes before it.
    constexpr std::size_t record_capacity = FileLimits::path_bytes + 256;

    constexpr FileState stateOf(char letter) noexcept {
      switch (letter) {
      case 'M':
      case 'T':
        return FileState::modified;
      case 'A':
      case 'C':
        return FileState::added;
      case 'D':
        return FileState::deleted;
      case 'R':
        return FileState::renamed;
      case 'U':
        return FileState::conflicted;
      default:
        return FileState::unchanged;
      }
    }

    // What follows the `count`th space of `text`; empty when it has fewer.
    constexpr std::string_view afterSpaces(std::string_view text, std::size_t count) noexcept {
      for (std::size_t passed = 0; passed < count; ++passed) {
        const auto space = text.find(' ');
        if (space == std::string_view::npos) {
          return {};
        }

        text.remove_prefix(space + 1);
      }

      return text;
    }

    bool valid(std::string_view text) noexcept {
      return inspectUtf8(text) == Utf8Validation::valid;
    }

    // The directory a path is in, and its name there.
    struct Place {
      std::string_view directory;
      std::string_view name;
    };

    constexpr Place placeOf(std::string_view path) noexcept {
      const auto slash = path.find_last_of('/');
      if (slash == 0) {
        return {.directory = "/", .name = path.substr(1)};
      }

      return {.directory = path.substr(0, slash), .name = path.substr(slash + 1)};
    }

  }

  ds::Option<StatusRecord> StatusRecord::parse(std::string_view record) noexcept {
    // The records of a changed path and of one in conflict: their letters, then six or eight
    // fields, then the path.
    constexpr std::size_t ordinary_fields = 8;
    constexpr std::size_t unmerged_fields = 10;

    if (record.size() < 3 || record[1] != ' ') {
      return ds::none;
    }

    switch (record.front()) {
    case '?':
      return StatusRecord{.path = record.substr(2), .unstaged = FileState::untracked};
    case '!':
      return StatusRecord{.path = record.substr(2), .unstaged = FileState::ignored};
    case '1':
    case '2': {
      const auto path = afterSpaces(record, ordinary_fields + (record.front() == '2' ? 1 : 0));
      if (path.empty() || record.size() < 4) {
        return ds::none;
      }

      return StatusRecord{.path = path, .staged = stateOf(record[2]), .unstaged = stateOf(record[3])};
    }
    case 'u': {
      const auto path = afterSpaces(record, unmerged_fields);
      if (path.empty()) {
        return ds::none;
      }

      return StatusRecord{.path = path, .staged = FileState::conflicted, .unstaged = FileState::conflicted};
    }
    default:
      return ds::none;
    }
  }

  RepositoryReader::RepositoryReader(ConcurrentMemory& memory)
      : memory_(memory),
        record_(memory),
        text_(memory),
        changes_(memory),
        root_(memory),
        branch_(memory),
        head_(memory),
        diff_(memory) {}

  std::string_view RepositoryReader::pathOf(const Change& change) const noexcept {
    return std::string_view{text_.data(), text_.size()}.substr(change.path, change.path_size);
  }

  template <typename Record>
  bool RepositoryReader::feed(std::span<const Byte> bytes, Record&& record) {
    for (const auto byte : bytes) {
      const auto character = static_cast<char>(byte);
      if (character != '\0') {
        // A record longer than any path is passed over whole.
        if (record_.size() < record_capacity) {
          record_.push(character);
        } else {
          oversized_ = true;
        }

        continue;
      }

      const bool more = oversized_ || record(std::string_view{record_.data(), record_.size()});

      record_.clear();
      oversized_ = false;
      if (!more) {
        return false;
      }
    }

    return true;
  }

  bool RepositoryReader::keep(std::string_view record) {
    constexpr std::string_view head = "# branch.head ";
    constexpr std::string_view upstream = "# branch.upstream ";
    constexpr std::string_view distance = "# branch.ab ";

    if (record.starts_with(head)) {
      branch_.assign(runtime::utf8Prefix(record.substr(head.size()), FileLimits::branch_bytes));
      return true;
    }

    if (record.starts_with(upstream)) {
      upstream_ = true;
      return true;
    }

    if (record.starts_with(distance)) {
      // `+ahead -behind`.
      const auto counts = record.substr(distance.size());
      const auto space = counts.find(' ');
      if (space != std::string_view::npos && counts.starts_with('+') && counts.substr(space + 1).starts_with('-')) {
        ahead_ = parseExact<std::uint32_t>(counts.substr(1, space - 1)).valueOr(0);
        behind_ = parseExact<std::uint32_t>(counts.substr(space + 2)).valueOr(0);
      }

      return true;
    }

    const auto parsed = StatusRecord::parse(record);
    if (!parsed || parsed->path.size() > FileLimits::path_bytes) {
      return true;
    }

    if (changes_.size() == FileLimits::maximum_changes) {
      truncated_ = true;
      return false;
    }

    changes_.push({
        .path = static_cast<std::uint32_t>(text_.size()),
        .path_size = static_cast<std::uint16_t>(parsed->path.size()),
        .staged = parsed->staged,
        .unstaged = parsed->unstaged,
    });
    text_.extend(std::span<const char>{parsed->path});
    return true;
  }

  void RepositoryReader::count(std::string_view record) {
    // `added TAB removed TAB path`; a binary file's counts are `-`.
    const auto first = record.find('\t');
    const auto second = first == std::string_view::npos ? first : record.find('\t', first + 1);
    if (second == std::string_view::npos) {
      return;
    }

    const auto added = parseExact<std::uint32_t>(record.substr(0, first));
    const auto removed = parseExact<std::uint32_t>(record.substr(first + 1, second - first - 1));
    const auto path = record.substr(second + 1);
    if (!added || !removed) {
      return;
    }

    for (std::size_t step = 0; step < changes_.size(); ++step) {
      const auto index = (cursor_ + step) % changes_.size();
      auto& change = changes_.atMut(index);
      if (pathOf(change) == path) {
        change.added += *added;
        change.removed += *removed;
        cursor_ = index;
        return;
      }
    }
  }

  void RepositoryReader::changes(const QueryChanges& request, const std::atomic<bool>& cancelled, EncodedReply<ConcurrentMemory>& reply) {
    if (!request.path.starts_with('/')) {
      throw RequestError{FailureCode::invalid_request, "A repository's changes need an absolute directory"};
    }

    record_.clear();
    oversized_ = false;
    text_.clear();
    changes_.clear();
    cursor_ = 0;
    root_.clear();
    branch_.clear();
    upstream_ = false;
    ahead_ = 0;
    behind_ = 0;
    truncated_ = false;

    const auto deadline = Clock::now() + status_time;

    try {
      GitRepository git{memory_, request.path, deadline, cancelled};

      root_.assign(git.run({"rev-parse", "--show-toplevel"}));
      static_cast<void>(git.stream({"status", "--porcelain=v2", "--branch", "-z", "--no-renames", "--untracked-files=normal", "--ignored=traditional"}, [&](std::span<const Byte> bytes) {
        return feed(bytes, [&](std::string_view record) {
          return keep(record);
        });
      },
          deadline));

      const auto counted = [&](std::span<const Byte> bytes) {
        return feed(bytes, [&](std::string_view record) {
          count(record);
          return true;
        });
      };

      // The lines of what the working tree changed, then of what the index holds.
      if (!changes_.empty()) {
        record_.clear();
        static_cast<void>(git.stream({"diff", "--numstat", "-z", "--no-renames"}, counted, deadline));
        record_.clear();
        static_cast<void>(git.stream({"diff", "--cached", "--numstat", "-z", "--no-renames"}, counted, deadline));
      }
    } catch (const SystemError&) {
      // Without git every path shows as committed.
      root_.clear();
    } catch (const RequestError&) {
      // Outside a repository, or out of time: what was read by then is what there is.
      if (changes_.empty()) {
        root_.clear();
      } else {
        truncated_ = true;
      }
    }

    ds::Vec<FileChange, ConcurrentMemory> listed{memory_};

    listed.reserve(changes_.size());
    for (const auto& change : changes_) {
      listed.push({.path = pathOf(change), .staged = change.staged, .unstaged = change.unstaged, .added = change.added, .removed = change.removed});
    }

    reply.send(RepositoryChanges{
        .request_id = request.request_id,
        .path = request.path,
        .root = root_.view().size() > FileLimits::path_bytes ? std::string_view{} : root_.view(),
        .branch = valid(branch_.view()) ? branch_.view() : std::string_view{},
        .upstream = upstream_,
        .ahead = ahead_,
        .behind = behind_,
        .truncated = truncated_,
        .changes = listed.view(),
    });
  }

  void RepositoryReader::inspect(const InspectFile& request, const std::atomic<bool>& cancelled, EncodedReply<ConcurrentMemory>& reply) {
    if (!request.path.starts_with('/') || request.path.size() < 2) {
      throw RequestError{FailureCode::invalid_request, "A preview needs an absolute path"};
    }

    const ds::String<ConcurrentMemory> path{memory_, request.path};
    struct stat status{};
    if (::lstat(path.data(), &status) != 0) {
      throw RequestError{FailureCode::invalid_request, "The path does not exist"};
    }

    const auto kind = kindOf(status.st_mode);
    ds::Array<char, FileLimits::path_bytes> target{};
    std::size_t target_size = 0;
    bool binary = false;
    bool truncated = false;

    if (kind == FileKind::link) {
      const auto read = ::readlink(path.data(), target.viewMut().data(), target.size());

      target_size = read < 0 ? 0 : static_cast<std::size_t>(read);
    }

    head_.clear();
    if (kind == FileKind::file) {
      const FileDescriptor file{::open(path.data(), combineFlags(O_RDONLY, O_NOFOLLOW, O_NONBLOCK, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic

      // A character cut at the end of what is read is no reason to call the file binary.
      head_.resize(FileLimits::text_bytes);
      const auto read = file ? ::read(file.get(), head_.dataMut(), head_.size()) : 0;

      head_.truncate(read < 0 ? 0 : static_cast<std::size_t>(read));
      truncated = static_cast<std::uint64_t>(std::max<off_t>(0, status.st_size)) > head_.size();

      const auto text = runtime::utf8Prefix(std::string_view{head_.data(), head_.size()}, truncated ? head_.size() - 1 : head_.size());

      binary = text.contains('\0') || !valid(text);
      head_.truncate(binary ? 0 : text.size());
    }

    // The last commit that changed it, and the diff of what is not committed.
    ds::Array<char, FileLimits::commit_bytes> commit{};
    std::size_t commit_size = 0;
    std::uint64_t committed = 0;
    ds::String<ConcurrentMemory> subject{memory_};

    diff_.clear();

    const auto place = placeOf(request.path);
    const auto deadline = Clock::now() + inspection_time;

    try {
      GitRepository git{memory_, place.directory, deadline, cancelled};
      const auto logged = git.run({"log", "-1", "--format=%H%x09%ct%x09%s", "--", place.name});
      const auto first = logged.find('\t');
      const auto second = first == std::string_view::npos ? first : logged.find('\t', first + 1);

      if (second != std::string_view::npos && first == FileLimits::commit_bytes) {
        std::ranges::copy(logged.substr(0, first), commit.viewMut().begin());
        commit_size = first;
        committed = parseExact<std::uint64_t>(logged.substr(first + 1, second - first - 1)).valueOr(0);
        subject.assign(runtime::utf8Prefix(logged.substr(second + 1), FileLimits::subject_bytes));
      }

      if (kind == FileKind::file) {
        static_cast<void>(git.stream({"diff", "HEAD", "--no-color", "--no-ext-diff", "--", place.name}, [&](std::span<const Byte> bytes) {
          const auto room = FileLimits::diff_bytes - std::min(diff_.size(), FileLimits::diff_bytes);
          const auto taken = std::min(room, bytes.size());

          diff_.extend(std::span<const char>{reinterpret_cast<const char*>(bytes.data()), taken}); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the program's bytes are the diff's text
          if (taken < bytes.size()) {
            truncated = true;
            return false;
          }

          return true;
        },
            deadline));
      }
    } catch (const SystemError&) {  // NOLINT(bugprone-empty-catch): without git a preview shows the file alone
    } catch (const RequestError&) { // NOLINT(bugprone-empty-catch): outside a repository a preview shows the file alone
    }

    // Its hunks, without the header that names the file; whole lines, and text a client can show.
    auto diff = std::string_view{diff_.data(), diff_.size()};
    const auto hunk = diff.starts_with("@@") ? 0 : diff.find("\n@@");

    diff = hunk == std::string_view::npos ? std::string_view{} : diff.substr(hunk == 0 ? 0 : hunk + 1);
    if (diff_.size() == FileLimits::diff_bytes) {
      diff = diff.substr(0, diff.find_last_of('\n') + 1);
    }

    reply.send(FileInspection{
        .request_id = request.request_id,
        .path = request.path,
        .kind = kind,
        .size = static_cast<std::uint64_t>(std::max<off_t>(0, status.st_size)),
        .identity = identityOf(status),
        .target = std::string_view{target.data(), target_size}.contains('\0') ? std::string_view{} : std::string_view{target.data(), target_size},
        .binary = binary,
        .truncated = truncated,
        .text = std::string_view{head_.data(), head_.size()},
        .commit = std::string_view{commit.data(), commit_size},
        .committed_seconds = committed,
        .subject = valid(subject.view()) ? subject.view() : std::string_view{},
        .diff = valid(diff) ? diff : std::string_view{},
    });
  }

}
