export module telar.git:config;

import std;
import telar.base.memory;
import telar.base.text;
import :format;

// A strict reader of git's config syntax. It only reports variables: nothing
// it reads is executed, and include/includeIf are ordinary, ignored entries.

namespace telar::git {

using telar::runtime::asciiEqualIgnoreCase;
using telar::runtime::asciiLower;

struct ConfigEntry {
  std::string_view section;    // as written; compare without case
  std::string_view subsection; // case preserved, except the legacy [section.sub] form
  std::string_view key;        // as written; compare without case
  std::optional<std::string_view> value;
};

inline bool configKeyCharacter(char character) noexcept {
  return (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') || (character >= '0' && character <= '9') || character == '-';
}

inline bool configSpace(char character) noexcept {
  return character == ' ' || character == '\t' || character == '\v' || character == '\f' || character == '\r';
}

// Visits each variable of `text` in order and returns false on the first
// malformed line, as git refuses such a file. `scratch` holds the unescaped
// subsection and value; it grows once to twice the file size.
template <Allocator Memory, typename Visitor>
bool parseConfig(std::string_view text, String<Memory> &scratch, Visitor &&visit) {
  scratch.resize(2 * text.size() + 2);
  char *const subsection_buffer = scratch.data();
  char *const value_buffer = scratch.data() + text.size() + 1;
  if (text.starts_with("\xef\xbb\xbf")) {
    text.remove_prefix(3);
  }

  std::size_t position = 0;
  bool end = false;
  // git's get_next_char: CRLF reads as LF and the end of input as a final LF.
  const auto next = [&]() noexcept -> char {
    if (position >= text.size()) {
      end = true;
      return '\n';
    }
    auto character = text[position++];
    if (character == '\r' && position < text.size() && text[position] == '\n') {
      character = text[position++];
    }
    return character;
  };

  std::string_view section;
  std::string_view subsection;
  bool have_section = false;
  for (;;) {
    auto character = next();
    if (end) {
      return true;
    }
    if (character == '\n' || configSpace(character)) {
      continue;
    }
    if (character == '#' || character == ';') {
      while (next() != '\n') {
      }
      continue;
    }
    if (character == '[') {
      const auto start = position;
      std::size_t length = 0;
      std::size_t dot = std::string_view::npos;
      bool extended = false;
      for (;;) {
        character = next();
        if (end || character == '\n') {
          return false;
        }
        if (character == ']') {
          break;
        }
        if (configSpace(character)) {
          extended = true;
          break;
        }
        if (!configKeyCharacter(character) && character != '.') {
          return false;
        }
        if (character == '.' && dot == std::string_view::npos) {
          dot = length;
        }
        ++length;
      }
      const auto name = text.substr(start, length);
      std::size_t subsection_length = 0;
      if (extended) {
        do {
          character = next();
        } while (configSpace(character));
        if (character != '"') {
          return false;
        }
        for (;;) {
          character = next();
          if (character == '\n') {
            return false;
          }
          if (character == '"') {
            break;
          }
          if (character == '\\') {
            character = next();
            if (character == '\n') {
              return false;
            }
          }
          subsection_buffer[subsection_length++] = character;
        }
        if (next() != ']') {
          return false;
        }
        section = name;
        subsection = {subsection_buffer, subsection_length};
      } else if (dot != std::string_view::npos) {
        // The legacy [section.subsection] form lowercases its subsection.
        const auto legacy = name.substr(dot + 1);
        for (const auto byte : legacy) {
          subsection_buffer[subsection_length++] = asciiLower(byte);
        }
        section = name.substr(0, dot);
        subsection = {subsection_buffer, subsection_length};
      } else {
        section = name;
        subsection = {};
      }
      if (section.empty()) {
        return false;
      }
      have_section = true;
      continue;
    }
    if (!configKeyCharacter(character) || character == '-' || (character >= '0' && character <= '9') || !have_section) {
      return false;
    }

    const auto key_start = position - 1;
    std::size_t key_length = 1;
    for (;;) {
      character = next();
      if (end || !configKeyCharacter(character)) {
        break;
      }
      ++key_length;
    }
    const auto key = text.substr(key_start, key_length);
    while (character == ' ' || character == '\t') {
      character = next();
    }
    std::optional<std::string_view> value;
    if (character != '\n') {
      if (character != '=') {
        return false;
      }
      std::size_t length = 0;
      std::size_t spaces = 0;
      bool quoted = false;
      bool comment = false;
      for (;;) {
        character = next();
        if (character == '\n') {
          if (quoted) {
            return false;
          }
          break;
        }
        if (comment) {
          continue;
        }
        if (configSpace(character) && !quoted) {
          if (length != 0) {
            ++spaces;
          }
          continue;
        }
        if (!quoted && (character == ';' || character == '#')) {
          comment = true;
          continue;
        }
        for (; spaces != 0; --spaces) {
          value_buffer[length++] = ' ';
        }
        if (character == '\\') {
          character = next();
          switch (character) {
          case '\n':
            continue;
          case 't':
            character = '\t';
            break;
          case 'b':
            character = '\b';
            break;
          case 'n':
            character = '\n';
            break;
          case '\\':
          case '"':
            break;
          default:
            return false;
          }
          value_buffer[length++] = character;
          continue;
        }
        if (character == '"') {
          quoted = !quoted;
          continue;
        }
        value_buffer[length++] = character;
      }
      value = std::string_view{value_buffer, length};
    }
    if (!visit(ConfigEntry{section, subsection, key, value})) {
      return true;
    }
    if (end) {
      return true;
    }
  }
}

// git's boolean spellings; anything else is not a boolean.
inline std::optional<bool> configBoolean(std::optional<std::string_view> value) noexcept {
  if (!value) {
    return true;
  }
  for (const auto yes : {"true", "yes", "on", "1"}) {
    if (asciiEqualIgnoreCase(*value, yes)) {
      return true;
    }
  }
  for (const auto no : {"false", "no", "off", "0", ""}) {
    if (asciiEqualIgnoreCase(*value, no)) {
      return false;
    }
  }
  return std::nullopt;
}

}
