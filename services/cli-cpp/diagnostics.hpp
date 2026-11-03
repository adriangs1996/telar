#pragma once

#include "command_limit.hpp"
#include "control_session.hpp"
#include "diagnostics_options.hpp"
#include "file_transfer.hpp"
#include "telar_platform/runtime_paths.hpp"
#include <ctime>
#include <dirent.h>
#include <memory>

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
    const RuntimePaths paths{memory, server_options, ProcessEnvironment{}};
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
