#pragma once

#include "../diagnostics/trace.hpp"
#include "../history/database.hpp"
#include "session_file.hpp"
#include "telar_base/text/json.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_platform/error.hpp"
#include "telar_platform/file_descriptor.hpp"
#include <fcntl.h>
#include <sys/stat.h>

namespace telar::runtime {

template <Allocator Memory>
class SessionFileReader {
public:
  using Request = SessionFileRequest;
  using Result = SessionFileResult;

  explicit SessionFileReader(Memory &memory)
      : path_(AllocatorRef<char, Memory>{memory}),
        bytes_(AllocatorRef<char, Memory>{memory}),
        decoded_(AllocatorRef<char, Memory>{memory}) {}

  Result observe(const Request &request) noexcept {
    TELAR_TRACE("agents.readSessionTitle");
    Result result{.request = request, .offset = request.watch.offset, .title = std::nullopt};
    try {
      path_ = request.watch.path.view();
      switch (request.watch.kind) {
      case AgentSessionFileKind::claude_transcript:
        claude(request.watch, result);
        break;
      case AgentSessionFileKind::codex_state:
        codex(request.watch, result);
        break;
      case AgentSessionFileKind::cursor_meta:
        cursor(request.watch, result);
        break;
      }
    } catch (const std::exception &) {
    }

    return result;
  }

  void stop() noexcept {}

private:
  void codex(const SessionFileWatch &watch, Result &result) {
    Database database{path_.c_str(), DatabaseAccess::read_only};
    Statement statement{database, "SELECT name FROM threads WHERE id = ?1"};
    statement.bind(1, watch.session.view());
    if (statement.next()) {
      result.title.emplace().assign(utf8Prefix(statement.text(0), title_capacity));
    }
  }

  static bool cursorPath(std::string_view path, std::string_view session) noexcept {
    if (session.empty() || session.size() > 64 || !std::ranges::all_of(session, [](char byte) { return (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f') || (byte >= 'A' && byte <= 'F') || byte == '-'; })) {
      return false;
    }
    if (!path.ends_with("/meta.json")) {
      return false;
    }

    path.remove_suffix(sizeof("/meta.json") - 1);
    return path.substr(path.rfind('/') + 1) == session;
  }

  void cursor(const SessionFileWatch &watch, Result &result) {
    if (!cursorPath(path_, watch.session.view())) {
      return;
    }

    FileDescriptor file{::open(path_.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC)};
    const auto size = regularFileSize(file);
    if (!size || *size >= metadata_capacity) {
      return;
    }

    const auto input = read(file.get(), 0, metadata_capacity);
    if (input.size() == metadata_capacity) {
      return;
    }

    result.title = readTitle(input, std::nullopt);
  }

  void claude(const SessionFileWatch &watch, Result &result) {
    FileDescriptor file{::open(path_.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC)};
    if (!file) {
      if (!watch.offset) {
        result.offset = 0;
      }
      return;
    }

    const auto size = regularFileSize(file);
    if (!size) {
      return;
    }
    if (!watch.offset) {
      result.offset = *size;
      return;
    }

    const auto from = *size < *watch.offset ? 0 : *watch.offset;
    const auto input = read(file.get(), from, transcript_capacity);
    std::size_t consumed = 0;
    while (consumed < input.size()) {
      const auto newline = input.find('\n', consumed);
      if (newline == std::string_view::npos) {
        break;
      }

      const auto line = input.substr(consumed, newline - consumed);
      consumed = newline + 1;
      if (line.size() > line_capacity || !line.starts_with("{\"type\":\"custom-title\"")) {
        continue;
      }

      try {
        if (const auto title = readTitle(line, watch.session.view())) {
          result.title = title;
        }
      } catch (const std::exception &) {
      }
    }

    result.offset = from + (consumed == 0 && input.size() == transcript_capacity ? input.size() : consumed);
  }

  std::optional<FixedText<96>> readTitle(std::string_view input, std::optional<std::string_view> session) {
    validateUtf8(input);
    const auto object = JsonValue::parse(input);
    FixedText<96> title;
    bool has_title = false;
    bool has_session = false;
    bool matches_session = !session;
    object.eachMember([&](const JsonValue &key, const JsonValue &value) {
      key.string(decoded_);
      if (decoded_ == (session ? "customTitle" : "title")) {
        if (has_title) {
          throw EncodingError{"Duplicate session title"};
        }

        has_title = true;
        value.string(decoded_);
        title.assign(utf8Prefix(decoded_, title_capacity));
      } else if (session && decoded_ == "sessionId") {
        if (has_session) {
          throw EncodingError{"Duplicate session reference"};
        }

        has_session = true;
        value.string(decoded_);
        matches_session = decoded_ == *session;
      }
    });

    return matches_session ? std::optional{title} : std::nullopt;
  }

  static std::optional<std::uint64_t> regularFileSize(const FileDescriptor &file) noexcept {
    struct stat metadata{};
    if (!file || ::fstat(file.get(), &metadata) != 0 || !S_ISREG(metadata.st_mode) || metadata.st_size < 0) {
      return std::nullopt;
    }

    return static_cast<std::uint64_t>(metadata.st_size);
  }

  std::string_view read(int descriptor, std::uint64_t offset, std::size_t limit) {
    bytes_.resize(limit);
    std::size_t filled = 0;
    while (filled < limit) {
      if (offset > static_cast<std::uint64_t>(INT64_MAX) - filled) {
        throw EncodingError{"Agent session file offset is outside its bounds"};
      }

      const auto count = ::pread(descriptor, bytes_.data() + filled, limit - filled, static_cast<off_t>(offset + filled));
      if (count < 0 && errno == EINTR) {
        continue;
      }
      if (count < 0) {
        throw SystemError{"Read agent session file"};
      }
      if (count == 0) {
        break;
      }

      filled += static_cast<std::size_t>(count);
    }

    return {bytes_.data(), filled};
  }

  static constexpr std::size_t title_capacity = 96;
  static constexpr std::size_t metadata_capacity = 16 * 1024;
  static constexpr std::size_t transcript_capacity = 64 * 1024;
  static constexpr std::size_t line_capacity = 4096;
  String<Memory> path_;
  Vector<char, Memory> bytes_;
  String<Memory> decoded_;
};

}
