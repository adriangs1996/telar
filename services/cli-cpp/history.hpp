#pragma once

#include "ensure_runtime.hpp"
#include "history_import.hpp"
#include <ctime>

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

inline HistoryScopeValue scopeValue(const HistoryOptions &options, const std::string &cwd) {
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

template <Allocator Memory>
HistoryResults query(ControlSession<Memory> &session, const HistoryOptions &options, const HistoryScopeValue &scope) {
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
    const RuntimePaths paths{memory, server_options, ProcessEnvironment{}};
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
