module;
#include <concepts>
#include <cstddef>
#include <cstring>
#include <exception>
#include <memory>
#include <span>
#include <type_traits>
#include <limits>
#include <variant>
#include <vector>
#include <algorithm>
#include <bit>
#include <chrono>
#include <utility>
#include <cstdlib>
#include <mutex>
#include <new>

#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>

#include <array>
#include <cstdint>

#include <charconv>
#include <cstdio>

export module telar.cli.output;

import telar.base.diagnostics;
import telar.base.memory;
import telar.base.text;
import telar.client.protocol;


// Interface: failure.cppm
export {
namespace telar::runtime::cli {

// A command that failed after its arguments parsed: `what()` is the text after
// the family's prefix on stderr, `status` the exit status (2 for a missing
// target, 3 for a timeout), and `code` the runtime's refusal, if any.
class Failure : public std::runtime_error {
public:
  inline explicit Failure(std::string_view message, int status = 1, std::optional<FailureCode> code = std::nullopt)
      : std::runtime_error{std::string{message}},
        status_(status),
        code_(code) {}

  [[nodiscard]] inline int status() const noexcept {
    return status_;
  }

  [[nodiscard]] inline std::optional<FailureCode> code() const noexcept {
    return code_;
  }

private:
  int status_;
  std::optional<FailureCode> code_;
};

}
}

// Interface: family.cppm
export {
namespace telar::runtime::cli {

// The first word of a command line that names a group of commands, as `worktree`
// in `telar worktree create`. A word that is no family is a program to run in a
// pane of a window.
enum class Family : std::uint8_t {
  workspace,
  tab,
  pane,
  worktree,
  agent,
  exec,
  repository,
  project,
  file,
  machine,
  client,
  sidebar,
  workspace_list,
  layout,
  notification,
  command,
  config,
  plugin,
  integration,
  hook,
  cli,
  gui,
  server,
  runtime,
  diagnostics,
  history,
  proxy,
  api,
  clipboard,
  count
};

// Each family as it is typed, in the order of `Family`.
inline constexpr std::array<std::string_view, static_cast<std::size_t>(Family::count)> family_names{
    "workspace", "tab", "pane", "worktree", "agent", "exec", "repository", "project", "file", "machine",
    "client", "sidebar", "workspace-list", "layout", "notification", "command", "config", "plugin",
    "integration", "hook", "cli", "gui", "server", "runtime", "diagnostics", "history", "proxy", "api", "clipboard"};

inline std::string_view familyName(Family family) noexcept {
  return family_names.at(static_cast<std::size_t>(family));
}

inline std::optional<Family> parseFamily(std::string_view word) noexcept {
  for (std::size_t index = 0; index < family_names.size(); ++index) {
    if (family_names.at(index) == word) {
      return static_cast<Family>(index);
    }
  }

  return std::nullopt;
}

}
}

// Interface: json_text.cppm
export {
namespace telar::runtime::cli {

// The two ways the Zig CLI escaped JSON strings; `--json` output keeps each
// command's own. `standard` is std.json.Stringify: \b \f \n \r \t shorthands and
// \u00XX for other control bytes. `control` is control.writeJsonString: only
// \n \r \t shorthands, and DEL escaped too.
enum class JsonEscapes : std::uint8_t {
  standard,
  control
};

inline std::optional<char> jsonShorthand(unsigned char byte, JsonEscapes escapes) noexcept {
  switch (byte) {
  case '\n':
    return 'n';
  case '\r':
    return 'r';
  case '\t':
    return 't';
  case '\b':
    return escapes == JsonEscapes::standard ? std::optional<char>{'b'} : std::nullopt;
  case '\f':
    return escapes == JsonEscapes::standard ? std::optional<char>{'f'} : std::nullopt;
  default:
    return std::nullopt;
  }
}

// Appends `text` as one JSON string literal, quotes included.
template <typename CharacterAllocator>
void appendJsonText(std::basic_string<char, std::char_traits<char>, CharacterAllocator> &output, std::string_view text, JsonEscapes escapes) {
  constexpr std::string_view hex = "0123456789abcdef";
  constexpr unsigned char first_printable = 0x20;
  constexpr unsigned char delete_byte = 0x7f;
  output.push_back('"');
  for (const unsigned char byte : text) {
    if (byte == '"' || byte == '\\') {
      output.push_back('\\');
      output.push_back(static_cast<char>(byte));
    } else if (const auto shorthand = jsonShorthand(byte, escapes)) {
      output.push_back('\\');
      output.push_back(*shorthand);
    } else if (byte < first_printable || (byte == delete_byte && escapes == JsonEscapes::control)) {
      output += "\\u00";
      output.push_back(hex[byte >> 4]);
      output.push_back(hex[byte & 15]);
    } else {
      output.push_back(static_cast<char>(byte));
    }
  }

  output.push_back('"');
}

}
}

// Interface: output.cppm
export {
namespace telar::runtime::cli {

// A command's stdout, built in memory and written once, so a failure halfway
// prints nothing of the result.
template <Allocator Memory>
class Output {
public:
  inline explicit Output(Memory &memory)
      : data(AllocatorRef<char, Memory>{memory}) {}

  inline Output &text(std::string_view value) {
    data.append(value);
    return *this;
  }

  template <typename Integer>
  inline Output &number(Integer value) {
    std::array<char, 32> buffer;
    const auto end = std::to_chars(buffer.data(), buffer.data() + buffer.size(), value).ptr;
    data.append(buffer.data(), end);
    return *this;
  }

  inline Output &boolean(bool value) {
    return text(value ? "true" : "false");
  }

  inline Output &json(std::string_view value, JsonEscapes escapes = JsonEscapes::standard) {
    appendJsonText(data, value, escapes);
    return *this;
  }

  inline void flush() {
    std::fwrite(data.data(), 1, data.size(), stdout);
    std::fflush(stdout);
    data.clear();
  }

  String<Memory> data;
};

}
}
