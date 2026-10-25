#pragma once

#include "../memory/allocator.hpp"
#include "../runtime/request_error.hpp"
#include <charconv>
#include <span>

namespace telar::runtime {

class JsonValue {
public:
  explicit JsonValue(std::string_view bytes, unsigned maximum_depth = 32)
      : bytes_(bytes),
        maximum_depth_(maximum_depth) {}

  std::string_view encoded() const noexcept {
    return bytes_;
  }

  template <typename Consumer>
  void eachElement(Consumer &&consume) const {
    auto input = bytes_;
    take(input, '[');
    whitespace(input);
    if (input.starts_with(']')) {
      return;
    }

    for (;;) {
      const auto before = input;
      skip(input, 0, maximum_depth_);
      consume(JsonValue{before.substr(0, before.size() - input.size()), maximum_depth_});
      whitespace(input);
      if (input.starts_with(']')) {
        return;
      }

      take(input, ',');
      whitespace(input);
    }
  }

  template <typename Consumer>
  void eachMember(Consumer &&consume) const {
    auto input = bytes_;
    take(input, '{');
    whitespace(input);
    if (input.starts_with('}')) {
      return;
    }

    for (;;) {
      const auto key_start = input;
      stringToken(input);
      const JsonValue key{key_start.substr(0, key_start.size() - input.size()), maximum_depth_};
      whitespace(input);
      take(input, ':');
      whitespace(input);
      const auto before = input;
      skip(input, 0, maximum_depth_);
      consume(key, JsonValue{before.substr(0, before.size() - input.size()), maximum_depth_});
      whitespace(input);
      if (input.starts_with('}')) {
        return;
      }

      take(input, ',');
      whitespace(input);
    }
  }

  std::optional<JsonValue> field(std::string_view name) const {
    auto input = bytes_;
    whitespace(input);
    take(input, '{');
    while (true) {
      whitespace(input);
      if (input.starts_with('}')) {
        return std::nullopt;
      }
      const auto key = stringToken(input);
      whitespace(input);
      take(input, ':');
      whitespace(input);
      const auto before = input;
      skip(input, 0, maximum_depth_);
      const auto value = before.substr(0, before.size() - input.size());
      if (key == name) {
        return JsonValue{value, maximum_depth_};
      }
      whitespace(input);
      if (input.starts_with('}')) {
        return std::nullopt;
      }
      take(input, ',');
    }
  }

  bool equals(std::string_view expected) const {
    auto input = bytes_;
    return input.starts_with('"') && stringToken(input) == expected;
  }

  bool boolean() const noexcept {
    return bytes_ == "true";
  }

  template <Allocator Memory>
  void string(String<Memory> &output) const {
    auto input = bytes_;
    const auto encoded = stringToken(input);
    output.clear();
    for (std::size_t index = 0; index < encoded.size(); ++index) {
      const char byte = encoded[index];
      if (byte != '\\') {
        output.push_back(byte);
        continue;
      }
      if (++index == encoded.size()) {
        invalid();
      }
      switch (encoded[index]) {
      case '"':
      case '\\':
      case '/':
        output.push_back(encoded[index]);
        break;
      case 'b':
        output.push_back('\b');
        break;
      case 'f':
        output.push_back('\f');
        break;
      case 'n':
        output.push_back('\n');
        break;
      case 'r':
        output.push_back('\r');
        break;
      case 't':
        output.push_back('\t');
        break;
      case 'u': {
        auto codepoint = hex(encoded, index + 1);
        index += 4;
        if (codepoint >= 0xd800 && codepoint <= 0xdbff) {
          if (encoded.substr(index + 1, 2) != "\\u") {
            invalid();
          }
          const auto low = hex(encoded, index + 3);
          if (low < 0xdc00 || low > 0xdfff) {
            invalid();
          }
          codepoint = 0x10000 + ((codepoint - 0xd800) << 10) + low - 0xdc00;
          index += 6;
        } else if (codepoint >= 0xdc00 && codepoint <= 0xdfff) {
          invalid();
        }
        appendUtf8(output, codepoint);
        break;
      }
      default:
        invalid();
      }
    }
  }

  static JsonValue parse(std::string_view input, unsigned maximum_depth = 32) {
    whitespace(input);
    const auto original = input;
    skip(input, 0, maximum_depth);
    const auto value = original.substr(0, original.size() - input.size());
    whitespace(input);
    if (!input.empty()) {
      invalid();
    }
    return JsonValue{value, maximum_depth};
  }

private:
  [[noreturn]] static void invalid() {
    throw RequestError{FailureCode::invalid_request, "Invalid JSON record"};
  }

  static void whitespace(std::string_view &input) noexcept {
    const auto end = input.find_first_not_of(" \r\n\t");
    input.remove_prefix(end == std::string_view::npos ? input.size() : end);
  }

  static void take(std::string_view &input, char byte) {
    if (!input.starts_with(byte)) {
      invalid();
    }
    input.remove_prefix(1);
  }

  static std::uint32_t hex(std::string_view input, std::size_t offset) {
    if (offset > input.size() || input.size() - offset < 4) {
      invalid();
    }
    std::uint32_t value = 0;
    const auto result = std::from_chars(input.data() + offset, input.data() + offset + 4, value, 16);
    if (result.ec != std::errc{} || result.ptr != input.data() + offset + 4) {
      invalid();
    }
    return value;
  }

  static std::string_view stringToken(std::string_view &input) {
    take(input, '"');
    const auto original = input;
    std::size_t index = 0;
    while (index < original.size()) {
      const auto byte = static_cast<unsigned char>(original[index]);
      if (byte == '"') {
        input.remove_prefix(index + 1);
        return original.substr(0, index);
      }
      if (byte < 0x20) {
        invalid();
      }
      if (byte == '\\') {
        if (++index == original.size()) {
          invalid();
        }
        if (original[index] == 'u') {
          hex(original, index + 1);
          index += 4;
        } else if (std::string_view{"\"\\/bfnrt"}.find(original[index]) == std::string_view::npos) {
          invalid();
        }
      }
      ++index;
    }
    invalid();
  }

  static void skip(std::string_view &input, unsigned depth, unsigned maximum_depth) {
    if (depth > maximum_depth || input.empty()) {
      invalid();
    }
    if (input.front() == '"') {
      stringToken(input);
      return;
    }
    if (input.front() == '{' || input.front() == '[') {
      const bool object = input.front() == '{';
      const char close = object ? '}' : ']';
      input.remove_prefix(1);
      whitespace(input);
      if (input.starts_with(close)) {
        input.remove_prefix(1);
        return;
      }
      for (;;) {
        if (object) {
          stringToken(input);
          whitespace(input);
          take(input, ':');
          whitespace(input);
        }
        skip(input, depth + 1, maximum_depth);
        whitespace(input);
        if (input.starts_with(close)) {
          input.remove_prefix(1);
          return;
        }
        take(input, ',');
        whitespace(input);
      }
    }

    const auto end = input.find_first_of(",]} \r\n\t");
    const auto atom = input.substr(0, end);
    if (atom != "true" && atom != "false" && atom != "null") {
      auto number = atom;
      if (number.starts_with('-')) {
        number.remove_prefix(1);
      }
      if (number.empty()) {
        invalid();
      }
      if (number.front() == '0') {
        number.remove_prefix(1);
      } else {
        if (number.front() < '1' || number.front() > '9') {
          invalid();
        }
        digits(number);
      }
      if (number.starts_with('.')) {
        number.remove_prefix(1);
        if (digits(number) == 0) {
          invalid();
        }
      }
      if (number.starts_with('e') || number.starts_with('E')) {
        number.remove_prefix(1);
        if (number.starts_with('+') || number.starts_with('-')) {
          number.remove_prefix(1);
        }
        if (digits(number) == 0) {
          invalid();
        }
      }
      if (!number.empty()) {
        invalid();
      }
    }
    input.remove_prefix(atom.size());
  }

  static std::size_t digits(std::string_view &input) noexcept {
    const auto length = input.find_first_not_of("0123456789");
    const auto consumed = length == std::string_view::npos ? input.size() : length;
    input.remove_prefix(consumed);
    return consumed;
  }

  template <Allocator Memory>
  static void appendUtf8(String<Memory> &output, std::uint32_t value) {
    if (value < 0x80) {
      output.push_back(static_cast<char>(value));
    } else if (value < 0x800) {
      output.push_back(static_cast<char>(0xc0 | (value >> 6)));
      output.push_back(static_cast<char>(0x80 | (value & 0x3f)));
    } else if (value < 0x10000) {
      output.push_back(static_cast<char>(0xe0 | (value >> 12)));
      output.push_back(static_cast<char>(0x80 | ((value >> 6) & 0x3f)));
      output.push_back(static_cast<char>(0x80 | (value & 0x3f)));
    } else {
      output.push_back(static_cast<char>(0xf0 | (value >> 18)));
      output.push_back(static_cast<char>(0x80 | ((value >> 12) & 0x3f)));
      output.push_back(static_cast<char>(0x80 | ((value >> 6) & 0x3f)));
      output.push_back(static_cast<char>(0x80 | (value & 0x3f)));
    }
  }

  std::string_view bytes_;
  unsigned maximum_depth_;
};

template <Allocator Memory>
void appendJsonString(String<Memory> &output, std::string_view text) {
  constexpr std::string_view hex = "0123456789abcdef";
  output.push_back('"');
  for (const unsigned char byte : text) {
    if (byte == '"' || byte == '\\') {
      output.push_back('\\');
      output.push_back(static_cast<char>(byte));
    } else if (byte < 0x20) {
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
