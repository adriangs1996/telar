#pragma once

#include "command_limit.hpp"
#include "control_session.hpp"
#include "file_transfer.hpp"
#include "history_options.hpp"
#include <filesystem>

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
  explicit ImportParser(HistoryOptions::ImportKind kind)
      : kind_(kind) {}

  std::optional<ImportedLine> feed(std::string_view line) {
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

  std::optional<ImportedLine> flush() {
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
  static std::int64_t timestamp(std::string_view text) {
    try {
      constexpr auto max_seconds = std::numeric_limits<std::int64_t>::max() / 1000;
      constexpr auto min_seconds = std::numeric_limits<std::int64_t>::min() / 1000;
      const auto seconds = parseInteger<std::int64_t>(text);
      return seconds > max_seconds || seconds < min_seconds ? 0 : seconds * 1000;
    } catch (const std::invalid_argument &) {
      return 0;
    }
  }

  void append(std::string_view bytes) {
    if (bytes.empty()) {
      return;
    }

    bytes_ += bytes.size();
    last_ = bytes.back();
    if (bytes_ <= max_command_bytes) {
      command_ += bytes;
    }
  }

  void begin(std::int64_t time, std::string_view command) {
    time_ = time;
    bytes_ = 0;
    last_ = 0;
    active_ = true;
    command_.clear();
    append(command);
  }

  std::optional<ImportedLine> zsh(std::string_view line) {
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

  std::optional<ImportedLine> plain(std::string_view line) {
    if (line.empty()) {
      return std::nullopt;
    }

    auto finished = flush();
    begin(time_, line);
    return finished ? finished : flush();
  }

  std::optional<ImportedLine> bash(std::string_view line) {
    if (line.size() > 1 && line.front() == '#') {
      try {
        const auto seconds = parseInteger<std::int64_t>(line.substr(1));
        auto finished = flush();
        time_ = timestamp(std::to_string(seconds));
        return finished;
      } catch (const std::invalid_argument &) {
      }
    }

    return plain(line);
  }

  std::optional<ImportedLine> fish(std::string_view line) {
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
