module;
#include "tbc/view.hpp"
#include <stdlib.h>
#include <new>

#include <cstdint>
#include <cerrno>
#include <unistd.h>

#include <cstdio>
#include <fcntl.h>
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#include <sys/stat.h>
#if (defined(__linux__))
#include <sys/syscall.h>
#endif

#include <cstddef>
#include <cstring>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <limits.h>
#include <cstdlib>
#include <ctime>
#include <dirent.h>

#if (defined(__APPLE__))
#include <mach-o/dyld.h>
#endif
#include <csignal>
#include <spawn.h>
#include <sys/wait.h>




export module telar.cli.history;

import std;

export import telar.cli.command_limit;


export import telar.platform;


export import telar.cli.runtime_observer;


export import telar.cli.server;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;

// Interface: diagnostics_options.cppm
export {
namespace telar::runtime::cli {

struct DiagnosticsOptions {
  enum class Action {
    logs,
    limits
  };
  enum class Component {
    all,
    runtime,
    client
  };
  static constexpr std::uint16_t default_lines = 100;
  static constexpr std::uint16_t max_lines = 10000;
  Action action;
  Component component = Component::all;
  std::optional<std::uint32_t> pid = std::nullopt;
  std::uint16_t lines = default_lines;
  bool json = false;
  std::optional<std::string_view> socket = std::nullopt;

  inline static DiagnosticsOptions parse(Arguments words) {
    if (words.empty() || (std::string_view{words.front()} != "logs" && std::string_view{words.front()} != "limits")) {
      throw std::invalid_argument{"UnknownDiagnosticsAction"};
    }

    DiagnosticsOptions self{.action = std::string_view{words.front()} == "logs" ? Action::logs : Action::limits};
    Cursor cursor{words.subspan(1)};
    while (const auto word = cursor.next()) {
      const std::string_view arg = *word;
      if (arg == "--component" && self.action == Action::logs) {
        const auto value = cursor.take("MissingComponent");
        if (value != "all" && value != "runtime" && value != "client") {
          throw std::invalid_argument{"InvalidComponent"};
        }

        self.component = value == "all" ? Component::all : value == "runtime" ? Component::runtime
                                                                              : Component::client;
      } else if (arg == "--pid" && !self.pid && self.action == Action::logs) {
        self.pid = number<std::uint32_t>(cursor.take("MissingPid"), "InvalidPid");
        if (*self.pid == 0) {
          throw std::invalid_argument{"InvalidPid"};
        }
      } else if (arg == "--lines" && self.action == Action::logs) {
        self.lines = number<std::uint16_t>(cursor.take("MissingLineCount"), "InvalidLineCount");
        if (self.lines == 0 || self.lines > max_lines) {
          throw std::invalid_argument{"InvalidLineCount"};
        }
      } else if (arg == "--json" && !self.json) {
        self.json = true;
      } else if (arg == "--socket" && !self.socket) {
        self.socket = cursor.take("MissingSocketPath");
      } else {
        throw std::invalid_argument{"UnknownDiagnosticsOption"};
      }
    }

    return self;
  }
};

}
}

// Interface: file_transfer.cppm
export {
#ifdef __linux__
#endif

namespace telar::runtime::cli::file_transfer {

inline constexpr std::uint64_t max_bytes = 128 * 1024 * 1024;
inline constexpr std::size_t copy_buffer_bytes = 64 * 1024;

inline const char *fileError(int code) {
  switch (code) {
  case ENOENT:
    return "FileNotFound";
  case ENOTDIR:
    return "NotDir";
  case EACCES:
  case EPERM:
    return "AccessDenied";
  case EEXIST:
    return "PathAlreadyExists";
  case ELOOP:
    return "SymLinkLoop";
  case ENAMETOOLONG:
    return "NameTooLong";
  case ENOSPC:
    return "NoSpaceLeft";
  default:
    return "InputOutput";
  }
}

struct Options {
  enum class Action {
    put,
    get
  };
  Action action;
  std::string path;
  std::uint64_t bytes = 0;

  inline static Options parse(Arguments words) {
    if (words.size() != 2 && words.size() != 4) {
      throw std::invalid_argument{"InvalidFileArguments"};
    }

    if (!std::string_view{words[1]}.starts_with('/')) {
      throw std::invalid_argument{"AbsoluteFilePathRequired"};
    }

    const std::string_view action = words.front();
    if (action != "put" && action != "get") {
      throw std::invalid_argument{"UnknownFileAction"};
    }

    Options self{.action = action == "put" ? Action::put : Action::get, .path = words[1]};
    if (words.size() == 4) {
      if (self.action != Action::put || std::string_view{words[2]} != "--bytes") {
        throw std::invalid_argument{"InvalidFileArguments"};
      }

      self.bytes = parseUnsigned<std::uint64_t>(words[3]);
    } else if (self.action == Action::put) {
      throw std::invalid_argument{"MissingTransferByteCount"};
    }

    return self;
  }
};

// Walk with directory descriptors: no ancestor, including the final parent,
// may redirect a transfer through a symlink between validation and opening.
inline FileDescriptor openDirectory(std::string_view path, bool create = false) {
  if (!path.starts_with('/')) {
    throw std::runtime_error{"AbsoluteFilePathRequired"};
  }

  FileDescriptor current{::open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
  if (!current) {
    throw std::runtime_error{fileError(errno)};
  }

  std::size_t start = 1;
  while (start < path.size()) {
    const auto end = path.find('/', start);
    const auto component = path.substr(start, end == path.npos ? path.size() - start : end - start);
    start = end == path.npos ? path.size() : end + 1;
    if (component.empty()) {
      continue;
    }

    if (component == "." || component == "..") {
      throw std::runtime_error{"InvalidFilePath"};
    }

    const std::string name{component};
    auto next = ::openat(current.get(), name.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (next < 0 && errno == ENOENT && create) {
      if (::mkdirat(current.get(), name.c_str(), 0700) != 0 && errno != EEXIST) {
        throw std::runtime_error{fileError(errno)};
      }

      next = ::openat(current.get(), name.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    }

    if (next < 0) {
      throw std::runtime_error{fileError(errno)};
    }

    current.reset(next);
  }

  struct stat inode{};
  if (::fstat(current.get(), &inode) != 0) {
    throw std::runtime_error{fileError(errno)};
  }

  if (inode.st_uid != ::getuid() || (inode.st_mode & 0022) != 0) {
    throw std::runtime_error{"UnsafeTransferDirectory"};
  }

  return current;
}

inline FileDescriptor openParent(std::string_view path) {
  const auto slash = path.rfind('/');
  if (slash == path.npos) {
    throw std::runtime_error{"InvalidFilePath"};
  }

  return openDirectory(path.substr(0, slash == 0 ? 1 : slash));
}

inline FileDescriptor openRegular(int parent, const char *name) {
  FileDescriptor file{::openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)};
  if (!file) {
    throw std::runtime_error{errno == ENOENT ? "FileNotFound" : "UnsafeTransferFile"};
  }

  struct stat inode{};
  if (::fstat(file.get(), &inode) != 0 || !S_ISREG(inode.st_mode) || inode.st_uid != ::getuid() || inode.st_nlink != 1) {
    throw std::runtime_error{"UnsafeTransferFile"};
  }

  return file;
}

inline void checkSize(std::uint64_t size) {
  if (size > max_bytes) {
    reportCommandLimit({.name = "file_transfer.max_bytes", .noun = "bytes", .value = max_bytes, .requested = size});
    throw std::runtime_error{"FileTransferLimit"};
  }
}

inline std::uint64_t copy(int input, int output) {
  std::array<Byte, copy_buffer_bytes> buffer;
  std::uint64_t total = 0;
  for (;;) {
    const auto count = ::read(input, buffer.data(), buffer.size());
    if (count < 0 && errno == EINTR) {
      continue;
    }

    if (count < 0) {
      throw std::runtime_error{fileError(errno)};
    }

    if (count == 0) {
      return total;
    }

    total += static_cast<std::uint64_t>(count);
    checkSize(total);
    writeBytes(output, std::span{buffer}.first(static_cast<std::size_t>(count)));
  }
}

inline void publish(int parent, const char *temporary, const char *name) {
#if defined(__APPLE__) || defined(__linux__)
  const auto result = renameAt(parent, temporary, parent, name, RenameMode::create_only);
#else
  const auto result = ::linkat(parent, temporary, parent, name, 0);
  if (result == 0) {
    ::unlinkat(parent, temporary, 0);
  }
#endif
  if (result != 0) {
    throw std::runtime_error{fileError(errno)};
  }
}

inline void transfer(const Options &options) {
  if (options.action == Options::Action::put) {
    checkSize(options.bytes);
  }

  auto parent = openParent(options.path);
  const auto slash = options.path.rfind('/');
  const auto name = options.path.substr(slash + 1);
  if (name.empty() || name == "." || name == "..") {
    throw std::runtime_error{"InvalidFilePath"};
  }

  if (options.action == Options::Action::get) {
    auto file = openRegular(parent.get(), name.c_str());
    struct stat inode{};
    if (::fstat(file.get(), &inode) != 0) {
      throw std::runtime_error{fileError(errno)};
    }

    checkSize(static_cast<std::uint64_t>(inode.st_size));
    copy(file.get(), STDOUT_FILENO);
    return;
  }

  const auto temporary = std::format(".telar-file-{:016x}{:016x}", randomIdentity(), randomIdentity());
  FileDescriptor file{::openat(parent.get(), temporary.c_str(), O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600)};
  if (!file) {
    throw std::runtime_error{fileError(errno)};
  }

  try {
    const auto size = copy(STDIN_FILENO, file.get());
    if (size != options.bytes) {
      throw std::runtime_error{"FileTransferInterrupted"};
    }

    if (::fsync(file.get()) != 0) {
      throw std::runtime_error{fileError(errno)};
    }

    publish(parent.get(), temporary.c_str(), name.c_str());
    writeText(std::format("{{\"bytes\":{},\"published\":true}}\n", size));
  } catch (...) {
    ::unlinkat(parent.get(), temporary.c_str(), 0);
    throw;
  }
}

inline int run(const Options &options) {
  try {
    transfer(options);
    return 0;
  } catch (const std::exception &error) {
    writeText("telar file: " + std::string{error.what()} + "\n", STDERR_FILENO);
    return 1;
  }
}

}
}

// Interface: diagnostics.cppm
export {
namespace telar::runtime::cli::diagnostics {

inline constexpr std::size_t max_files = 64;
inline constexpr std::size_t max_directory_entries = 64 * 1024;
inline constexpr std::size_t max_tail_bytes = 1024 * 1024;

struct Log {
  std::string name;
  DiagnosticsOptions::Component component;
  std::uint32_t pid;
};

inline std::optional<Log> parseLog(std::string_view name, std::string_view base) {
  if (!name.starts_with(base) || !name.ends_with(".log")) {
    return std::nullopt;
  }

  auto suffix = name.substr(base.size(), name.size() - base.size() - std::string_view{".log"}.size());
  auto component = DiagnosticsOptions::Component::all;
  if (suffix.starts_with(".runtime-")) {
    component = DiagnosticsOptions::Component::runtime;
    suffix.remove_prefix(std::string_view{".runtime-"}.size());
  } else if (suffix.starts_with(".client-")) {
    component = DiagnosticsOptions::Component::client;
    suffix.remove_prefix(std::string_view{".client-"}.size());
  } else {
    return std::nullopt;
  }

  const auto pid = maybeUnsigned<std::uint32_t>(suffix);
  if (pid && *pid != 0) {
    return Log{.name = std::string{name}, .component = component, .pid = *pid};
  }

  return std::nullopt;
}

inline std::string_view tail(std::string_view bytes, std::uint16_t lines) {
  if (bytes.empty()) {
    return bytes;
  }

  auto index = bytes.size() - (bytes.back() == '\n' ? 1 : 0);
  std::size_t found = 0;
  while (index != 0) {
    if (bytes[--index] == '\n' && ++found == lines) {
      return bytes.substr(index + 1);
    }
  }

  return bytes;
}

inline std::vector<Log> findLogs(DIR *directory, std::string_view base, const DiagnosticsOptions &options) {
  std::vector<Log> logs;
  std::size_t visited = 0;
  std::size_t skipped = 0;
  while (const auto *entry = ::readdir(directory)) {
    if (std::string_view{entry->d_name} == "." || std::string_view{entry->d_name} == "..") {
      continue;
    }

    if (++visited > max_directory_entries) {
      reportCommandLimit({.name = "cli.diagnostic_directory_entries", .noun = "entries", .value = max_directory_entries});
      break;
    }

    if (entry->d_type != DT_REG) {
      continue;
    }

    auto log = parseLog(entry->d_name, base);
    if (!log || (options.component != DiagnosticsOptions::Component::all && options.component != log->component) || (options.pid && log->pid != *options.pid)) {
      continue;
    }

    if (logs.size() == max_files) {
      ++skipped;
      continue;
    }

    logs.push_back(std::move(*log));
  }

  if (options.component != DiagnosticsOptions::Component::client && !options.pid) {
    for (const auto suffix : {".runtime.start.log", ".runtime.log"}) {
      std::string name = std::string{base} + suffix;
      struct stat state{};
      if (::fstatat(::dirfd(directory), name.c_str(), &state, 0) == 0) {
        logs.push_back({.name = std::move(name), .component = DiagnosticsOptions::Component::runtime, .pid = 0});
      }
    }
  }

  if (skipped != 0) {
    reportCommandLimit({.name = "cli.diagnostic_logs", .noun = "logs", .value = max_files, .requested = max_files + skipped});
  }

  if (logs.empty()) {
    throw std::runtime_error{"DiagnosticLogsNotFound"};
  }

  std::sort(logs.begin(), logs.end(), [](const auto &left, const auto &right) { return left.name < right.name; });
  return logs;
}

inline void readLogs(std::string_view endpoint, const DiagnosticsOptions &options) {
  const auto slash = endpoint.rfind('/');
  if (slash == endpoint.npos) {
    throw std::runtime_error{"InvalidSocketPath"};
  }

  const auto parent = std::string{endpoint.substr(0, slash)};
  const auto base = endpoint.substr(slash + 1);
  std::unique_ptr<DIR, decltype(&::closedir)> directory{::opendir(parent.c_str()), &::closedir};
  if (!directory) {
    throw std::runtime_error{errno == ENOENT ? "DiagnosticLogsNotFound" : file_transfer::fileError(errno)};
  }

  const auto logs = findLogs(directory.get(), base, options);
  std::string bytes(max_tail_bytes, '\0');
  std::string output = options.json ? "[" : "";
  for (const auto &log : logs) {
    FileDescriptor file{::openat(::dirfd(directory.get()), log.name.c_str(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)};
    if (!file) {
      throw std::runtime_error{"CannotOpenDiagnosticLog"};
    }

    struct stat inode{};
    if (::fstat(file.get(), &inode) != 0 || !S_ISREG(inode.st_mode) || inode.st_uid != ::getuid()) {
      throw std::runtime_error{"UnsafeDiagnosticLog"};
    }

    const auto offset = std::max<off_t>(0, inode.st_size - max_tail_bytes);
    std::size_t count = 0;
    while (count < bytes.size()) {
      const auto read = ::pread(file.get(), bytes.data() + count, bytes.size() - count, offset + count);
      if (read < 0 && errno == EINTR) {
        continue;
      }

      if (read < 0) {
        throw std::runtime_error{file_transfer::fileError(errno)};
      }

      if (read == 0) {
        break;
      }

      count += static_cast<std::size_t>(read);
    }

    auto text = std::string_view{bytes}.substr(0, count);
    if (offset != 0 && text.find('\n') != text.npos) {
      text.remove_prefix(text.find('\n') + 1);
    }

    const auto selected = tail(text, options.lines);
    const bool truncated = offset != 0 || selected.size() < text.size();
    const auto path = parent + "/" + log.name;
    if (options.json) {
      if (&log != logs.data()) {
        output += ',';
      }

      output += std::format("{{\"path\":{},\"component\":{},\"pid\":{},\"truncated\":{},\"text\":{}}}", quoteJson(path), quoteJson(log.component == DiagnosticsOptions::Component::runtime ? "runtime" : "client"), log.pid, jsonBoolean(truncated), quoteJson(selected));
    } else {
      output += path + (truncated ? " (tail)\n" : "\n");
      output += selected;
      if (selected.empty() || selected.back() != '\n') {
        output += '\n';
      }
    }
  }

  if (options.json) {
    output += "]\n";
  }

  writeText(output);
}

inline void printLimits(const LimitList &list, bool json) {
  std::string output;
  if (json) {
    output = std::format("{{\"runtime_evicted\":{},\"client_evicted\":{},\"refused_reports\":{},\"limits\":[", list.runtime_evicted, list.client_evicted, list.refused_reports);
  } else if (list.entries.empty()) {
    output = "no limit reached\n";
  }

  for (const auto &entry : list.entries) {
    const auto origin = entry.origin == LimitOrigin::runtime ? "runtime" : "client";
    if (json) {
      if (&entry != list.entries.data()) {
        output += ',';
      }

      output += std::format("{{\"name\":{},\"noun\":{},\"value\":{},\"requested\":{},\"route\":{},\"origin\":{},\"hits\":{},\"last_ms\":{}}}", quoteJson(entry.reach.name), quoteJson(entry.reach.noun), entry.reach.value, entry.reach.requested ? std::to_string(*entry.reach.requested) : "null", quoteJson(entry.reach.route), quoteJson(origin), entry.hits, entry.last_ms);
    } else {
      constexpr std::int64_t seconds_per_day = 24 * 60 * 60;
      constexpr std::int64_t seconds_per_hour = 60 * 60;
      constexpr std::int64_t seconds_per_minute = 60;
      const auto seconds = std::max<std::int64_t>(0, entry.last_ms / 1000) % seconds_per_day;
      output += std::format("{}  ({}{}{}, last {:02}:{:02}:{:02} UTC)\n", limitDescription(entry.reach, entry.hits), origin, entry.reach.route.empty() ? "" : ", ", entry.reach.route, seconds / seconds_per_hour, seconds / seconds_per_minute % seconds_per_minute, seconds % seconds_per_minute);
    }
  }

  if (json) {
    output += "]}\n";
  } else if (list.runtime_evicted != 0 || list.client_evicted != 0 || list.refused_reports != 0) {
    output += std::format("{} runtime and {} client limits replaced by newer ones; {} client reports refused\n", list.runtime_evicted, list.client_evicted, list.refused_reports);
  }

  writeText(output);
}

template <Allocator Memory>
int run(Memory &memory, const DiagnosticsOptions &options) {
  try {
    ServerOptions server_options{};
    server_options.socket = options.socket.value_or("");
    const RuntimePaths paths{memory, server_options, process_environment};
    if (options.action == DiagnosticsOptions::Action::logs) {
      readLogs(paths.socket, options);
    } else {
      ControlSession session{memory, paths.socket.c_str()};
      session.receiveTimeout(30);
      printLimits(session.template exchange<LimitList>(QueryLimits{}), options.json);
    }

    return 0;
  } catch (const std::exception &error) {
    const std::string_view reason = commandErrorName(error);
    writeText("telar diagnostics: " + std::string{reason} + "\n", STDERR_FILENO);
    if (reason == "DiagnosticLogsNotFound") {
      writeText("  the background runtime writes .runtime.log beside its socket once it starts;\n  per-process telemetry needs a build with -Ddiagnostics.\n", STDERR_FILENO);
      return 2;
    }

    return 1;
  }
}

}
}

// Interface: ensure_runtime.cppm
export {
namespace telar::runtime::cli {

// Connects to the runtime, starting it when none listens. Commands that only
// report must never resurrect a stopped runtime and do not call this.
template <Allocator Memory>
void ensureRuntime(Memory &memory, const RuntimePaths<Memory> &paths, const ServerOptions &options = {}) {
  std::optional<RuntimeConnection> connection;
  if (connectExisting(connection, paths.socket.c_str())) {
    return;
  }

  if (startRuntime(memory, options, paths) != RuntimeStart::listening) {
    throw std::runtime_error{"RuntimeUnavailable"};
  }
}

}
}

// Interface: history_options.cppm
export {
namespace telar::runtime::cli {

struct HistoryOptions {
  enum class Action {
    import,
    remove,
    prune,
    show,
    stats,
    list,
    search
  };
  enum class ImportKind {
    automatic,
    zsh,
    bash,
    fish
  };
  static constexpr std::uint16_t default_limit = 20;
  static constexpr std::uint16_t max_results = 1000;
  Action action;
  ImportKind import_kind = ImportKind::automatic;
  std::optional<std::string_view> import_file = std::nullopt;
  std::uint64_t id = 0;
  std::int64_t before_ms = 0;
  std::uint16_t period_days = 0;
  bool dry_run = false;
  bool assume_yes = false;
  std::string_view query;
  HistoryScope scope = HistoryScope::global;
  tbc::view<std::string_view, tbc::lt::a> scope_value;
  std::uint64_t pane_id = 0;
  bool failed_only = false;
  HistoryAuthorFilter author = HistoryAuthorFilter::all;
  std::uint16_t limit = default_limit;
  std::optional<std::string_view> socket = std::nullopt;

  inline void setScope(HistoryScope value, tbc::view<std::string_view, tbc::lt::a> path = {}) {
    if (scope != HistoryScope::global) {
      throw std::invalid_argument{"ConflictingHistoryScopes"};
    }

    scope = value;
    scope_value = path;
  }

  inline static ImportKind importKind(std::string_view value) {
    if (value == "auto") {
      return ImportKind::automatic;
    }
    if (value == "zsh") {
      return ImportKind::zsh;
    }
    if (value == "bash") {
      return ImportKind::bash;
    }
    if (value == "fish") {
      return ImportKind::fish;
    }

    throw std::invalid_argument{"UnknownHistoryImportKind"};
  }

  inline static std::int64_t parseBefore(std::string_view text) {
    constexpr std::int64_t milliseconds_per_second = 1000;
    if (!text.contains('-')) {
      const auto seconds = parseInt<std::int64_t>(text);
      if (seconds <= 0 || seconds > std::numeric_limits<std::int64_t>::max() / milliseconds_per_second) {
        throw std::invalid_argument{"InvalidHistoryBefore"};
      }

      return seconds * milliseconds_per_second;
    }

    std::array<std::int64_t, 3> fields{};
    for (std::size_t at = 0; at < fields.size(); ++at) {
      const auto end = text.find('-');
      if ((at != fields.size() - 1 && end == text.npos) || (at == fields.size() - 1 && end != text.npos)) {
        throw std::invalid_argument{"InvalidHistoryBefore"};
      }

      fields[at] = parseInt<std::int64_t>(text.substr(0, end));
      if (end != text.npos) {
        text.remove_prefix(end + 1);
      }
    }

    const auto [year, month, day] = fields;
    constexpr std::int64_t epoch_year = 1970;
    constexpr std::int64_t max_date_year = 292000000;
    if (year < epoch_year || year > max_date_year || month < 1 || month > 12 || day < 1 || day > 31) {
      throw std::invalid_argument{"InvalidHistoryBefore"};
    }

    const auto adjusted_year = month <= 2 ? year - 1 : year;
    constexpr std::int64_t years_per_era = 400;
    constexpr std::int64_t days_per_era = 146097;
    constexpr std::int64_t epoch_adjustment = 719468;
    constexpr std::int64_t milliseconds_per_day = 86400000;
    const auto era = adjusted_year / years_per_era;
    const auto year_of_era = adjusted_year - era * years_per_era;
    const auto adjusted_month = (month + 9) % 12;
    const auto day_of_year = (153 * adjusted_month + 2) / 5 + day - 1;
    const auto day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    return (era * days_per_era + day_of_era - epoch_adjustment) * milliseconds_per_day;
  }

  inline static HistoryOptions parse(Arguments words) {
    if (words.empty()) {
      throw std::invalid_argument{"MissingHistoryAction"};
    }

    const std::string_view action = words.front();
    HistoryOptions self{.action = Action::list};
    Cursor cursor{words.subspan(1)};
    if (action == "list") {
      self.action = Action::list;
    } else if (action == "stats") {
      self.action = Action::stats;
    } else if (action == "prune") {
      self.action = Action::prune;
    } else if (action == "search") {
      self.action = Action::search;
      self.query = cursor.take("MissingHistoryQuery");
    } else if (action == "show" || action == "delete") {
      self.action = action == "show" ? Action::show : Action::remove;
      self.id = parseInt<std::uint64_t>(cursor.take("MissingHistoryId"));
      if (self.id == 0) {
        throw std::invalid_argument{"InvalidHistoryId"};
      }
    } else if (action == "import") {
      self.action = Action::import;
      if (words.size() > 1 && !std::string_view{words[1]}.starts_with('-')) {
        self.import_kind = importKind(*cursor.next());
      }
    } else {
      throw std::invalid_argument{"UnknownHistoryAction"};
    }

    while (const auto word = cursor.next()) {
      const std::string_view arg = *word;
      if (arg == "--file" && self.action == Action::import) {
        self.import_file = cursor.take("MissingHistoryFile");
      } else if (arg == "--cwd") {
        self.setScope(HistoryScope::cwd);
      } else if (arg == "--workspace") {
        self.setScope(HistoryScope::workspace, cursor.take("MissingWorkspacePath"));
      } else if (arg == "--pane") {
        self.pane_id = parseInt<std::uint64_t>(cursor.take("MissingPaneId"));
        if (self.pane_id == 0) {
          throw std::invalid_argument{"InvalidPaneId"};
        }

        self.setScope(HistoryScope::pane);
      } else if (arg == "--failed") {
        self.failed_only = true;
      } else if (arg == "--period" && self.action == Action::stats) {
        const auto value = cursor.take("MissingHistoryPeriod");
        if (value == "today") {
          self.period_days = 1;
        } else if (value == "week") {
          self.period_days = 7;
        } else if (value == "month") {
          self.period_days = 30;
        } else if (value == "year") {
          self.period_days = 365;
        } else if (value == "all") {
          self.period_days = 0;
        } else {
          throw std::invalid_argument{"InvalidHistoryPeriod"};
        }
      } else if (arg == "--before" && self.action == Action::prune) {
        self.before_ms = parseBefore(cursor.take("MissingHistoryBefore"));
      } else if (arg == "--dry-run" && self.action == Action::prune) {
        self.dry_run = true;
      } else if (arg == "--yes" && self.action == Action::prune) {
        self.assume_yes = true;
      } else if (arg == "--match" && self.action == Action::prune) {
        self.query = cursor.take("MissingHistoryQuery");
      } else if (arg == "--author") {
        const auto value = cursor.take("MissingHistoryAuthor");
        if (value != "all" && value != "human" && value != "agent") {
          throw std::invalid_argument{"InvalidHistoryAuthor"};
        }

        self.author = value == "all" ? HistoryAuthorFilter::all : value == "human" ? HistoryAuthorFilter::human
                                                                                   : HistoryAuthorFilter::agent;
      } else if (arg == "--limit") {
        self.limit = parseInt<std::uint16_t>(cursor.take("MissingHistoryLimit"));
        if (self.limit == 0 || self.limit > max_results) {
          throw std::invalid_argument{"InvalidHistoryLimit"};
        }
      } else if (arg == "--socket") {
        const auto value = cursor.take("MissingSocketPath");
        if (self.socket) {
          throw std::invalid_argument{"DuplicateSocketOption"};
        }

        self.socket = value;
      } else {
        throw std::invalid_argument{"UnknownHistoryOption"};
      }
    }

    return self;
  }
};

}
}

// Interface: history_import.cppm
export {
namespace telar::runtime::cli::history {

inline constexpr std::size_t max_histfile_bytes = 32 * 1024 * 1024;
inline constexpr std::size_t max_command_bytes = 65535;
inline constexpr std::size_t max_batch_payload = 4 * max_command_bytes;
inline constexpr std::size_t max_import_entries = 64;

struct ImportedLine {
  std::int64_t started_at_ms;
  std::string command;
};

class ImportParser {
public:
  inline explicit ImportParser(HistoryOptions::ImportKind kind)
      : kind_(kind) {}

  inline std::optional<ImportedLine> feed(std::string_view line) {
    while (line.ends_with('\r')) {
      line.remove_suffix(1);
    }

    switch (kind_) {
    case HistoryOptions::ImportKind::zsh:
      return zsh(line);
    case HistoryOptions::ImportKind::bash:
      return bash(line);
    case HistoryOptions::ImportKind::fish:
      return fish(line);
    default:
      throw std::runtime_error{"UnknownHistoryImportKind"};
    }
  }

  inline std::optional<ImportedLine> flush() {
    if (!active_ || bytes_ == 0) {
      return std::nullopt;
    }

    active_ = false;
    if (bytes_ > command_.size()) {
      ++skipped;
      largest_skipped = std::max(largest_skipped, bytes_);
      return std::nullopt;
    }

    return ImportedLine{.started_at_ms = time_, .command = command_};
  }

  std::size_t skipped = 0;
  std::size_t largest_skipped = 0;

private:
  inline static std::int64_t timestamp(std::string_view text) {
    try {
      constexpr auto max_seconds = std::numeric_limits<std::int64_t>::max() / 1000;
      constexpr auto min_seconds = std::numeric_limits<std::int64_t>::min() / 1000;
      const auto seconds = parseInt<std::int64_t>(text);
      return seconds > max_seconds || seconds < min_seconds ? 0 : seconds * 1000;
    } catch (const std::invalid_argument &) {
      return 0;
    }
  }

  inline void append(std::string_view bytes) {
    if (bytes.empty()) {
      return;
    }

    bytes_ += bytes.size();
    last_ = bytes.back();
    if (bytes_ <= max_command_bytes) {
      command_ += bytes;
    }
  }

  inline void begin(std::int64_t time, std::string_view command) {
    time_ = time;
    bytes_ = 0;
    last_ = 0;
    active_ = true;
    command_.clear();
    append(command);
  }

  inline std::optional<ImportedLine> zsh(std::string_view line) {
    if (active_ && bytes_ != 0 && last_ == '\\') {
      --bytes_;
      if (bytes_ < command_.size()) {
        command_.resize(bytes_);
      }

      last_ = 0;
      append("\n");
      append(line);
      return line.ends_with('\\') ? std::nullopt : flush();
    }

    auto finished = flush();
    if (line.starts_with(": ")) {
      const auto semicolon = line.find(';');
      const auto colon = line.find(':', 2);
      if (semicolon == line.npos || colon == line.npos || colon >= semicolon) {
        return finished;
      }

      begin(timestamp(line.substr(2, colon - 2)), line.substr(semicolon + 1));
    } else if (!line.empty()) {
      begin(0, line);
    } else {
      return finished;
    }

    if (last_ == '\\' || finished) {
      return finished;
    }

    return flush();
  }

  inline std::optional<ImportedLine> plain(std::string_view line) {
    if (line.empty()) {
      return std::nullopt;
    }

    auto finished = flush();
    begin(time_, line);
    return finished ? finished : flush();
  }

  inline std::optional<ImportedLine> bash(std::string_view line) {
    if (line.size() > 1 && line.front() == '#') {
      try {
        const auto seconds = parseInt<std::int64_t>(line.substr(1));
        auto finished = flush();
        time_ = timestamp(std::to_string(seconds));
        return finished;
      } catch (const std::invalid_argument &) {
      }
    }

    return plain(line);
  }

  inline std::optional<ImportedLine> fish(std::string_view line) {
    constexpr std::string_view command_prefix = "- cmd: ";
    constexpr std::string_view time_prefix = "  when: ";
    if (line.starts_with(command_prefix)) {
      auto finished = flush();
      begin(0, line.substr(command_prefix.size()));
      return finished;
    }

    if (line.starts_with(time_prefix)) {
      time_ = timestamp(line.substr(time_prefix.size()));
      return flush();
    }

    return std::nullopt;
  }

  HistoryOptions::ImportKind kind_;
  std::int64_t time_ = 0;
  std::string command_;
  std::size_t bytes_ = 0;
  char last_ = 0;
  bool active_ = false;
};

inline std::pair<HistoryOptions::ImportKind, std::string> resolveImport(const HistoryOptions &options) {
  using Kind = HistoryOptions::ImportKind;
  if (options.import_file) {
    const auto file = *options.import_file;
    const auto kind = options.import_kind != Kind::automatic ? options.import_kind : file.ends_with("fish_history") ? Kind::fish
                                                                                 : file.contains("bash")            ? Kind::bash
                                                                                                                    : Kind::zsh;
    return {kind, std::string{file}};
  }

  const auto *home = ::getenv("HOME");
  if (home == nullptr) {
    throw std::runtime_error{"HistfileNotFound"};
  }

  constexpr std::array candidates{
      std::pair{Kind::zsh, "/.zsh_history"},
      std::pair{Kind::bash, "/.bash_history"},
      std::pair{Kind::fish, "/.local/share/fish/fish_history"},
  };
  for (const auto &[kind, suffix] : candidates) {
    if (options.import_kind != Kind::automatic && options.import_kind != kind) {
      continue;
    }

    std::string path = std::string{home} + suffix;
    if (::access(path.c_str(), F_OK) == 0) {
      return {kind, std::move(path)};
    }
  }

  throw std::runtime_error{"HistfileNotFound"};
}

inline std::pair<std::string, bool> newestLines(const std::string &path) {
  FileDescriptor file{::open(path.c_str(), O_RDONLY | O_CLOEXEC)};
  struct stat inode{};
  if (!file || ::fstat(file.get(), &inode) != 0) {
    throw std::runtime_error{file_transfer::fileError(errno)};
  }

  const auto size = static_cast<std::uint64_t>(inode.st_size);
  const auto offset = size > max_histfile_bytes ? size - max_histfile_bytes : 0;
  std::string text(size - offset, '\0');
  std::size_t used = 0;
  while (used < text.size()) {
    const auto count = ::pread(file.get(), text.data() + used, text.size() - used, static_cast<off_t>(offset + used));
    if (count < 0 && errno == EINTR) {
      continue;
    }

    if (count < 0) {
      throw std::runtime_error{file_transfer::fileError(errno)};
    }

    if (count == 0) {
      break;
    }

    used += static_cast<std::size_t>(count);
  }

  text.resize(used);
  if (offset != 0) {
    reportCommandLimit({.name = "history.max_histfile_bytes", .noun = "bytes", .value = max_histfile_bytes, .requested = size});
    const auto newline = text.find('\n');
    text.erase(0, newline == text.npos ? text.size() : newline + 1);
  }

  return {std::move(text), offset != 0};
}

struct ImportSource {
  HistoryOptions::ImportKind kind;
  std::string path;
  std::string text;
  bool truncated;
};

inline ImportSource loadImport(const HistoryOptions &options) {
  const auto [kind, path] = resolveImport(options);
  auto [text, truncated] = newestLines(path);
  return {.kind = kind, .path = path, .text = std::move(text), .truncated = truncated};
}

template <Allocator Memory>
int importHistory(ControlSession<Memory> &session, const ImportSource &input) {
  constexpr std::array kind_names{"auto", "zsh", "bash", "fish"};
  const auto source = std::string{kind_names.at(static_cast<std::size_t>(input.kind))} + ":" + input.path;
  std::vector<ImportedLine> batch;
  batch.reserve(max_import_entries);
  std::size_t used = 0;
  std::uint64_t total = 0;
  auto flush = [&] {
    if (batch.empty()) {
      return;
    }

    std::array<ImportHistoryEntry, max_import_entries> entries;
    for (std::size_t index = 0; index < batch.size(); ++index) {
      entries[index] = {.started_at_ms = batch[index].started_at_ms, .command = batch[index].command};
    }

    session.template exchange<RequestCompleted>(ImportHistory{.source = source, .base_sequence = total, .entries = std::span{entries}.first(batch.size())});
    total += batch.size();
    batch.clear();
    used = 0;
  };
  auto push = [&](std::optional<ImportedLine> entry) {
    if (!entry || entry->command.empty()) {
      return;
    }

    if (batch.size() == max_import_entries || used + entry->command.size() > max_batch_payload) {
      flush();
    }

    used += entry->command.size();
    batch.push_back(std::move(*entry));
  };
  ImportParser parser{input.kind};
  std::string_view remaining = input.text;
  for (;;) {
    const auto newline = remaining.find('\n');
    push(parser.feed(remaining.substr(0, newline)));
    if (newline == remaining.npos) {
      break;
    }

    remaining.remove_prefix(newline + 1);
  }

  push(parser.flush());
  flush();
  writeText(std::format("imported {} commands from {}\n", total, input.path));
  if (parser.skipped != 0) {
    const LimitReach reach{.name = "history.import_command_bytes", .noun = "bytes", .value = max_command_bytes, .requested = parser.largest_skipped};
    reportCommandLimit(reach);
    try {
      session.send(ReportLimit{.reach = reach, .hits = 1});
    } catch (const std::exception &) {
    }
  }

  return input.truncated || parser.skipped != 0 ? 1 : 0;
}

}
}

// Interface: history.cppm
export {
namespace telar::runtime::cli::history {

inline std::string field(std::string_view value) {
  std::string result;
  for (const unsigned char byte : value) {
    switch (byte) {
    case '\n':
      result += "\\n";
      break;
    case '\r':
      result += "\\r";
      break;
    case '\t':
      result += "\\t";
      break;
    default:
      if (byte < 0x20 || byte == 0x7f) {
        result += std::format("\\x{:02x}", byte);
      } else {
        result += static_cast<char>(byte);
      }
    }
  }

  return result;
}

inline void print(const HistoryResults &results) {
  std::string output;
  for (const auto &entry : results.entries) {
    const auto seconds = static_cast<time_t>(std::max<std::int64_t>(0, entry.started_at_ms / 1000));
    std::tm utc{};
    ::gmtime_r(&seconds, &utc);
    const auto status = entry.status == HistoryStatus::running ? "RUN" : entry.status == HistoryStatus::interrupted ? "INT"
                                                                     : entry.exit_code                              ? std::to_string(*entry.exit_code)
                                                                                                                    : "?";
    output += std::format("#{}  {:04}-{:02}-{:02} {:02}:{:02}:{:02}Z  {}  {}ms  {}  ", entry.id, utc.tm_year + 1900, utc.tm_mon + 1, utc.tm_mday, utc.tm_hour, utc.tm_min, utc.tm_sec, status, std::max<std::int64_t>(0, entry.duration_ns / 1000000), field(entry.cwd));
    if (entry.author == HistoryAuthor::agent && !entry.provider.empty()) {
      output += "\x1b[2m[" + field(entry.provider) + "]\x1b[22m ";
    }

    output += field(entry.command) + '\n';
  }

  writeText(output);
}

inline tbc::view<HistoryScopeValue, tbc::lt::a> scopeValue(tbc::view<const HistoryOptions &, tbc::lt::a> options, tbc::view<const std::string &, tbc::lt::a> cwd) {
  switch (options.scope) {
  case HistoryScope::cwd:
    return std::string_view{cwd};
  case HistoryScope::workspace:
    return options.scope_value;
  case HistoryScope::pane:
    return options.pane_id;
  case HistoryScope::global:
    return std::monostate{};
  }

  throw std::runtime_error{"InvalidHistoryScope"};
}

// The results view the session; region `b` keeps them apart from the options' own `a`.
template <Allocator Memory>
tbc::view<HistoryResults, tbc::lt::b> query(tbc::view<ControlSession<Memory> &, tbc::lt::b> session, const HistoryOptions &options, const HistoryScopeValue &scope) {
  return session.template exchange<HistoryResults>(QueryHistory{
      .query = options.query,
      .scope = options.scope,
      .scope_value = scope,
      .failed_only = options.failed_only,
      .author = options.author,
      .limit = options.limit,
  });
}

inline bool confirmPrune() {
  constexpr std::size_t confirmation_bytes = 16;
  std::string line;
  for (std::size_t index = 0; index < confirmation_bytes; ++index) {
    char byte = 0;
    const auto count = ::read(STDIN_FILENO, &byte, 1);
    if (count != 1) {
      return false;
    }

    if (byte == '\n') {
      const auto start = line.find_first_not_of(" \r");
      const auto end = line.find_last_not_of(" \r");
      return start != line.npos && line.substr(start, end - start + 1) == "yes";
    }

    line += byte;
  }

  return false;
}

template <Allocator Memory>
void prune(Memory &memory, const char *socket, ControlSession<Memory> &session, const HistoryOptions &options, const HistoryScopeValue &scope) {
  if (options.action == HistoryOptions::Action::remove) {
    const auto result = session.template exchange<HistoryPruned>(DeleteHistory{.id = options.id});
    writeText(std::format("removed {} entries\n", result.removed));
    return;
  }

  if (options.dry_run || !options.assume_yes) {
    auto preview = options;
    preview.author = HistoryAuthorFilter::all;
    preview.limit = HistoryOptions::max_results;
    const auto results = query(session, preview, scope);
    if (options.before_ms != 0) {
      writeText(std::format("{} newest entries match the text/scope filters; --before applies on top and is not previewable\n", results.entries.size()));
    } else {
      writeText(std::format("would remove {} entries (counting at most the newest {})\n", results.entries.size(), HistoryOptions::max_results));
    }

    if (options.dry_run) {
      return;
    }

    writeText("prune permanently? type yes to continue: ");
    if (!confirmPrune()) {
      writeText("aborted\n");
      return;
    }
  }

  ControlSession removal{memory, socket};
  removal.receiveTimeout(30);
  const auto result = removal.template exchange<HistoryPruned>(PruneHistory{
      .scope = options.scope,
      .scope_value = scope,
      .before_ms = options.before_ms,
      .failed_only = options.failed_only,
      .match = options.query,
  });
  writeText(std::format("removed {} entries\n", result.removed));
}

template <Allocator Memory>
void show(ControlSession<Memory> &session, const HistoryOptions &options) {
  const auto output = session.template exchange<HistoryOutput>(ReadHistoryOutput{.id = options.id});
  if (output.observed_bytes == 0) {
    writeText(std::format("telar history: no output captured for entry {} (runtime.history.output = \"bounded\" enables capture)\n", output.id), STDERR_FILENO);
    return;
  }

  writeBytes(STDOUT_FILENO, output.content);
  if (output.truncated) {
    writeText(std::format("telar history: output truncated ({} bytes observed)\n", output.observed_bytes), STDERR_FILENO);
  }
}

template <Allocator Memory>
void stats(ControlSession<Memory> &session, const HistoryOptions &options, const HistoryScopeValue &scope) {
  constexpr std::int64_t milliseconds_per_day = 86400000;
  const auto now = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
  const auto result = session.template exchange<HistoryStatsResult>(HistoryStatsQuery{
      .scope = options.scope,
      .scope_value = scope,
      .since_ms = options.period_days == 0 ? 0 : now - static_cast<std::int64_t>(options.period_days) * milliseconds_per_day,
  });
  auto output = std::format("commands: {}\nunique:   {}\n", result.total, result.unique);
  if (!result.top.empty()) {
    output += "top:\n";
  }

  for (const auto &entry : result.top) {
    output += std::format("  {:>7}  {}\n", entry.count, field(entry.command));
  }

  writeText(output);
}

template <Allocator Memory>
int run(Memory &memory, const HistoryOptions &options) {
  try {
    std::optional<ImportSource> input;
    if (options.action == HistoryOptions::Action::import) {
      input = loadImport(options);
    }

    ServerOptions server_options{};
    server_options.socket = options.socket.value_or("");
    const RuntimePaths paths{memory, server_options, process_environment};
    ensureRuntime(memory, paths);
    ControlSession session{memory, paths.socket.c_str(), max_payload_size, max_batch_payload + 2048};
    session.receiveTimeout(30);
    const auto cwd = options.scope == HistoryScope::cwd ? std::filesystem::canonical(".").string() : std::string{};
    const auto scope = scopeValue(options, cwd);
    switch (options.action) {
    case HistoryOptions::Action::import:
      return importHistory(session, *input);
    case HistoryOptions::Action::remove:
    case HistoryOptions::Action::prune:
      prune(memory, paths.socket.c_str(), session, options, scope);
      break;
    case HistoryOptions::Action::show:
      show(session, options);
      break;
    case HistoryOptions::Action::stats:
      stats(session, options, scope);
      break;
    case HistoryOptions::Action::list:
    case HistoryOptions::Action::search:
      print(query(session, options, scope));
      break;
    }

    return 0;
  } catch (const ControlFailure &error) {
    const auto context = options.action == HistoryOptions::Action::import ? "telar history import: " : "telar history: ";
    writeText(context + std::string{error.message().empty() ? error.what() : error.message()} + "\n", STDERR_FILENO);
    writeText(options.action == HistoryOptions::Action::import ? "error: HistoryImportFailed\n" : options.action == HistoryOptions::Action::remove || options.action == HistoryOptions::Action::prune ? "error: HistoryPruneFailed\n"
                                                                                                                                                                                                      : "error: HistoryQueryFailed\n",
              STDERR_FILENO);
    return 1;
  } catch (const std::exception &error) {
    writeText("error: " + std::string{error.what()} + "\n", STDERR_FILENO);
    return 1;
  }
}

}
}
