#pragma once

#include "../config_receive.hpp"
#include "../json_text.hpp"
#include "telar_base/text/json_node.hpp"
#include <cctype>
#include <set>

namespace telar::runtime::cli::machine::filter {

using config_receive::lower;

inline bool whitespace(char byte) {
  return byte == ' ' || byte == '\t' || byte == '\r' || byte == '\n' || byte == '\v' || byte == '\f';
}

inline std::string_view trim(std::string_view text, std::string_view characters = " \t\r\n") {
  const auto begin = text.find_first_not_of(characters);
  return begin == std::string_view::npos ? std::string_view{} : text.substr(begin, text.find_last_not_of(characters) + 1 - begin);
}

inline void noteOnce(std::vector<std::string> &notes, std::string_view name) {
  if (std::ranges::find(notes, name) == notes.end()) {
    notes.emplace_back(name);
  }
}

enum class Kind {
  scalar,
  text,
  container
};

inline bool secretKey(std::string_view name, Kind kind) {
  static constexpr auto dropped = std::to_array<std::string_view>({"env", "environment", "headers", "http_headers", "env_http_headers", "auth", "authInfo", "apiKeyHelper", "awsAuthRefresh", "awsCredentialExport", "otelHeadersHelper", "mcpServers", "mcp", "mcp_servers", "token", "accessToken", "access_token", "refreshToken", "refresh_token", "idToken", "id_token"});
  static constexpr auto fragments = std::to_array<std::string_view>({"secret", "password", "passphrase", "apikey", "api_key", "api-key", "credential", "bearer", "private_key", "privatekey", "authorization", "cookie"});
  const auto text = lower(name);
  return std::ranges::find(dropped, name) != dropped.end() || std::ranges::any_of(fragments, [&](auto fragment) { return text.contains(fragment); }) || (kind != Kind::scalar && (text.contains("token") || text.contains("auth")));
}

inline std::string rewriteHome(std::string_view bytes, std::string_view from, std::string_view to) {
  if (from.empty()) {
    throw CommandError{"HomeUnavailable"};
  }

  std::string output;
  for (;;) {
    const auto at = bytes.find(from);
    if (at == std::string_view::npos) {
      output += bytes;
      return output;
    }

    const auto after = at + from.size();
    const bool ends = after == bytes.size() || bytes[after] == '/' || bytes[after] == '"' || bytes[after] == '\'' || whitespace(bytes[after]);
    output += bytes.substr(0, at);
    output += ends ? to : from;
    bytes.remove_prefix(after);
  }
}

inline std::string stripJsonc(std::string_view bytes) {
  std::string result;
  bool string = false;
  for (std::size_t index = 0; index < bytes.size(); ++index) {
    const auto byte = bytes[index];
    if (string) {
      result += byte;
      if (byte == '\\' && index + 1 < bytes.size()) {
        result += bytes[++index];
      } else if (byte == '"') {
        string = false;
      }
    } else if (byte == '"') {
      string = true;
      result += byte;
    } else if (bytes.substr(index).starts_with("//")) {
      index = bytes.find('\n', index);
      if (index == std::string_view::npos) {
        break;
      }

      result += '\n';
    } else if (bytes.substr(index).starts_with("/*")) {
      const auto end = bytes.find("*/", index + 2);
      if (end == std::string_view::npos) {
        throw CommandError{"UnterminatedComment"};
      }

      index = end + 1;
    } else {
      result += byte;
    }
  }

  std::string plain;
  string = false;
  for (std::size_t index = 0; index < result.size(); ++index) {
    const auto byte = result[index];
    if (string) {
      plain += byte;
      if (byte == '\\' && index + 1 < result.size()) {
        plain += result[++index];
      } else if (byte == '"') {
        string = false;
      }
    } else if (byte == '"') {
      string = true;
      plain += byte;
    } else if (byte == ',') {
      auto next = index + 1;
      while (next < result.size() && whitespace(result[next])) {
        ++next;
      }

      if (next == result.size() || (result[next] != '}' && result[next] != ']')) {
        plain += byte;
      }
    } else {
      plain += byte;
    }
  }

  return plain;
}

template <Allocator Memory>
void json(Memory &memory, const JsonValue &value, String<Memory> &output, std::vector<std::string> &dropped) {
  const auto source = value.encoded();
  String<Memory> scratch{AllocatorRef<char, Memory>{memory}};
  if (source.starts_with('{')) {
    output += '{';
    bool first = true;
    value.eachMember([&](JsonValue key, JsonValue child) {
      key.string(scratch);
      const auto encoded = child.encoded();
      const auto kind = encoded.starts_with('"') ? Kind::text : encoded.starts_with('{') || encoded.starts_with('[') ? Kind::container
                                                                                                                     : Kind::scalar;
      if (secretKey(scratch, kind)) {
        noteOnce(dropped, scratch);
        return;
      }

      if (!first) {
        output += ',';
      }

      first = false;
      output += key.encoded();
      output += ':';
      json(memory, child, output, dropped);
    });
    output += '}';
  } else if (source.starts_with('[')) {
    output += '[';
    bool first = true;
    value.eachElement([&](JsonValue child) {
      if (!first) {
        output += ',';
      }

      first = false;
      json(memory, child, output, dropped);
    });
    output += ']';
  } else {
    output += source;
  }
}

inline std::size_t skipQuoted(std::string_view text, std::size_t start) {
  const auto quote = text[start];
  auto index = start + 1;
  while (index < text.size() && text[index] != quote) {
    index += quote == '"' && text[index] == '\\' ? 2 : 1;
  }

  return std::min(index, text.size());
}

struct TomlValue {
  char delimiter = 0;
  int depth = 0;

  bool open() const {
    return delimiter != 0 || depth > 0;
  }

  void scan(std::string_view text) {
    for (std::size_t index = 0; index < text.size();) {
      const auto tail = text.substr(index);
      if (delimiter != 0) {
        if (delimiter == '"' && text[index] == '\\') {
          index += 2;
          continue;
        }

        if ((delimiter == '"' && tail.starts_with("\"\"\"")) || (delimiter == '\'' && tail.starts_with("'''"))) {
          delimiter = 0;
          index += 3;
          continue;
        }
      } else if (tail.starts_with("\"\"\"") || tail.starts_with("'''")) {
        delimiter = text[index];
        index += 3;
        continue;
      } else {
        const auto byte = text[index];
        if (byte == '#') {
          return;
        }

        if (byte == '"' || byte == '\'') {
          index = skipQuoted(text, index);
        } else if (byte == '[' || byte == '{') {
          ++depth;
        } else if (byte == ']' || byte == '}') {
          --depth;
        }
      }

      ++index;
    }
  }
};

inline std::optional<std::string> tomlSecret(std::string_view path, Kind last) {
  constexpr std::size_t max_components = 16;
  std::vector<std::string_view> components;
  std::size_t start = 0;
  for (std::size_t index = 0; index <= path.size();) {
    if (index == path.size() || path[index] == '.') {
      if (components.size() == max_components) {
        return std::string{path};
      }

      components.push_back(trim(trim(path.substr(start, index - start), " \t"), "\"'"));
      start = ++index;
    } else {
      index = path[index] == '"' || path[index] == '\'' ? skipQuoted(path, index) + 1 : index + 1;
    }
  }

  static constexpr auto tables = std::to_array<std::string_view>({"mcp_servers", "projects", "shell_environment_policy"});
  if (std::ranges::find(tables, components.front()) != tables.end()) {
    return std::string{components.front()};
  }

  for (std::size_t index = 0; index < components.size(); ++index) {
    if (secretKey(components[index], index + 1 == components.size() ? last : Kind::container)) {
      return std::string{components[index]};
    }
  }

  return std::nullopt;
}

inline std::string toml(std::string_view bytes, std::vector<std::string> &dropped) {
  bool skipping_table = false;
  bool dropping_value = false;
  bool first = true;
  TomlValue value;
  std::string output;
  for (;;) {
    const auto newline = bytes.find('\n');
    const auto line = bytes.substr(0, newline);
    bool keep = !skipping_table;
    if (value.open()) {
      value.scan(line);
      keep = keep && !dropping_value;
    } else {
      const auto text = trim(line, " \t\r");
      if (text.starts_with('[')) {
        auto inner = text;
        while (inner.starts_with('[')) {
          inner.remove_prefix(1);
        }

        std::size_t index = 0;
        while (index < inner.size() && inner[index] != ']') {
          index = inner[index] == '"' || inner[index] == '\'' ? skipQuoted(inner, index) + 1 : index + 1;
        }

        const auto offending = tomlSecret(inner.substr(0, std::min(index, inner.size())), Kind::container);
        skipping_table = offending.has_value();
        keep = !skipping_table;
        if (offending) {
          noteOnce(dropped, *offending);
        }
      } else if (!text.empty() && !text.starts_with('#')) {
        std::size_t equals = 0;
        while (equals < text.size() && text[equals] != '=') {
          equals = text[equals] == '"' || text[equals] == '\'' ? skipQuoted(text, equals) + 1 : equals + 1;
        }

        if (equals < text.size()) {
          const auto rest = trim(text.substr(equals + 1), " \t");
          const auto kind = rest.empty() || rest.front() == '"' || rest.front() == '\'' ? Kind::text : rest.front() == '[' || rest.front() == '{' ? Kind::container
                                                                                                                                                  : Kind::scalar;
          const auto offending = tomlSecret(text.substr(0, equals), kind);
          dropping_value = offending.has_value();
          value.scan(rest);
          if (offending) {
            keep = false;
            if (!skipping_table) {
              noteOnce(dropped, *offending);
            }
          }
        }
      }
    }

    if (keep) {
      if (!first) {
        output += '\n';
      }

      first = false;
      output += line;
    }

    if (newline == std::string_view::npos) {
      break;
    }

    bytes.remove_prefix(newline + 1);
  }

  return output;
}

inline bool tokenByte(char byte) {
  return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '_' || byte == '-';
}

inline bool placeholder(char byte) {
  return std::string_view{"$<{%[(*"}.contains(byte);
}

inline bool secretName(std::string_view name) {
  if (name.size() > 128) {
    return false;
  }

  const auto text = lower(name);
  static constexpr auto names = std::to_array<std::string_view>({"key", "auth", "pat", "pwd"});
  static constexpr auto fragments = std::to_array<std::string_view>({"token", "secret", "passw", "api_key", "apikey", "api-key", "access_key", "accesskey", "private_key", "authorization", "credential", "webhook", "cookie"});
  static constexpr auto suffixes = std::to_array<std::string_view>({"_key", "-key", "_header", "-header", "_app", "-app"});
  return std::ranges::find(names, text) != names.end() || std::ranges::any_of(fragments, [&](auto fragment) { return text.contains(fragment); }) || std::ranges::any_of(suffixes, [&](auto suffix) { return text.ends_with(suffix); }) || text.starts_with("auth_") || text.starts_with("auth-");
}

inline std::optional<std::string_view> nextWord(std::string_view &rest) {
  rest = trim(rest, " \t");
  if (!rest.empty() && (rest.front() == '"' || rest.front() == '\'')) {
    rest.remove_prefix(1);
  }

  if (rest.empty() || placeholder(rest.front())) {
    return std::nullopt;
  }

  const auto end = rest.find_first_of(" \t\r\n\v\f\"',;");
  const auto word = rest.substr(0, end);
  rest.remove_prefix(end == std::string_view::npos ? rest.size() : end);
  return word;
}

inline bool literalValue(std::string_view rest, bool numbers) {
  auto word = nextWord(rest);
  if (!word) {
    return false;
  }

  const auto scheme = lower(*word);
  if (scheme == "bearer" || scheme == "basic" || scheme == "token" || scheme == "digest") {
    word = nextWord(rest);
  }

  if (!word || word->size() < 3) {
    return false;
  }

  const auto text = lower(*word);
  if (text == "true" || text == "false" || text == "null" || text == "none" || text == "undefined") {
    return false;
  }

  return numbers || std::ranges::any_of(*word, [](char byte) { return (byte < '0' || byte > '9') && byte != '.' && byte != '_'; });
}

inline std::optional<std::string_view> finding(std::string_view line) {
  const auto lowered = lower(line);
  if (line.contains("PRIVATE KEY-----")) {
    return "a private key";
  }

  static constexpr auto webhooks = std::to_array<std::string_view>({"hooks.slack.com/services/", "hooks.slack.com/workflows/", "hooks.slack.com/triggers/", "discord.com/api/webhooks/", "discordapp.com/api/webhooks/", ".webhook.office.com/", "outlook.office.com/webhook", "hooks.zapier.com/hooks/", "api.telegram.org/bot", "chat.googleapis.com/v1/spaces/", "ntfy.sh/"});
  if (std::ranges::any_of(webhooks, [&](auto marker) { return lowered.contains(marker); })) {
    return "a webhook URL, whose path is its key";
  }

  static constexpr auto prefixes = std::to_array<std::pair<std::string_view, std::size_t>>({{"ghp_", 20}, {"gho_", 20}, {"ghu_", 20}, {"ghs_", 20}, {"ghr_", 20}, {"github_pat_", 20}, {"glpat-", 20}, {"sk-", 20}, {"xoxb-", 10}, {"xoxp-", 10}, {"xoxa-", 10}, {"xoxr-", 10}, {"xoxs-", 10}, {"AKIA", 16}, {"ASIA", 16}, {"AIza", 30}, {"npm_", 30}, {"pypi-", 30}, {"hf_", 30}, {"r8_", 30}, {"tvly-", 20}});
  for (const auto &[prefix, minimum] : prefixes) {
    for (std::size_t start = 0;;) {
      const auto at = line.find(prefix, start);
      if (at == std::string_view::npos) {
        break;
      }

      start = at + 1;
      if (at != 0 && tokenByte(line[at - 1])) {
        continue;
      }

      auto end = at + prefix.size();
      while (end < line.size() && tokenByte(line[end])) {
        ++end;
      }

      if (end - at - prefix.size() >= minimum) {
        return "a token of a well-known format";
      }
    }
  }

  for (std::size_t start = 0;;) {
    const auto at = lowered.find("bearer", start);
    if (at == std::string::npos) {
      break;
    }

    start = at + 1;
    auto index = at + std::string_view{"bearer"}.size();
    const auto spaces = index;
    while (index < line.size() && (line[index] == ' ' || line[index] == '\t')) {
      ++index;
    }

    if (index == spaces || index == line.size() || placeholder(line[index])) {
      continue;
    }

    const auto begin = index;
    while (index < line.size() && (tokenByte(line[index]) || std::string_view{"._~+/="}.contains(line[index]))) {
      ++index;
    }

    if (index - begin >= 8) {
      return "a bearer token";
    }
  }

  for (std::size_t start = 0;;) {
    const auto at = line.find("://", start);
    if (at == std::string_view::npos) {
      break;
    }

    start = at + 3;
    const auto end = line.find_first_of("/?# \t\"'`<>", start);
    const auto authority = line.substr(start, end == std::string_view::npos ? line.size() - start : end - start);
    const auto sign = authority.rfind('@');
    const auto colon = authority.substr(0, sign).find(':');
    if (sign != std::string_view::npos && colon != std::string_view::npos && colon + 1 < sign && !placeholder(authority[colon + 1])) {
      return "a password inside a URL";
    }
  }

  const bool database = lowered.contains("mysql") || lowered.contains("mariadb");
  auto words = line;
  bool after_user = false;
  while (!words.empty()) {
    words = trim(words, " \t");
    const auto end = words.find_first_of(" \t");
    const auto word = trim(words.substr(0, end), "\"'");
    const auto user_password = [](std::string_view text) {
      const auto colon = text.find(':');
      return colon != std::string_view::npos && colon + 1 < text.size() && !placeholder(text[colon + 1]);
    };
    if (after_user && user_password(word)) {
      return "a password on a command line";
    }

    after_user = word == "-u" || word == "--user";
    if ((word.starts_with("--user=") && user_password(word.substr(7))) || (database && word.starts_with("-p") && word.size() > 2 && !placeholder(word[2]))) {
      return "a password on a command line";
    }

    if (end == std::string_view::npos) {
      break;
    }

    words.remove_prefix(end + 1);
  }

  const auto name_byte = [](char byte) { return tokenByte(byte) || byte == '.'; };
  for (std::size_t index = 0; index < line.size();) {
    if (!name_byte(line[index])) {
      ++index;
      continue;
    }

    const auto begin = index;
    while (index < line.size() && name_byte(line[index])) {
      ++index;
    }

    const auto name = line.substr(begin, index - begin);
    auto cursor = index;
    if (cursor < line.size() && (line[cursor] == '"' || line[cursor] == '\'')) {
      ++cursor;
    }

    while (cursor < line.size() && (line[cursor] == ' ' || line[cursor] == '\t')) {
      ++cursor;
    }

    if (cursor == line.size() || (line[cursor] != '=' && line[cursor] != ':') || line.substr(cursor).starts_with("://")) {
      continue;
    }

    ++cursor;
    if (cursor < line.size() && line[cursor] == '=') {
      continue;
    }

    if (secretName(name) && literalValue(line.substr(cursor), !lower(name).contains("token"))) {
      return "a value assigned to a secret-looking name";
    }
  }

  return std::nullopt;
}

inline std::optional<std::pair<std::size_t, std::string_view>> findSecret(std::string_view bytes) {
  std::size_t number = 1;
  for (;;) {
    const auto end = bytes.find('\n');
    if (const auto found = finding(bytes.substr(0, end))) {
      return std::pair{number, *found};
    }

    if (end == std::string_view::npos) {
      return std::nullopt;
    }

    bytes.remove_prefix(end + 1);
    ++number;
  }
}

}
