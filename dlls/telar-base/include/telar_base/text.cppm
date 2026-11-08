module;
#include "tbc/view.hpp"
#include "telar_base/program_identity.hpp"
#include "telar_base/text/base64.hpp"
#include <chrono>
#include <utility>
#include <cstddef>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <vector>

#include <string_view>

#include <concepts>
#include <limits>
#include <optional>

#include <initializer_list>

#include <cstdint>
#include <span>

#include <algorithm>

#include <exception>

#include <charconv>

#include <array>
#include <stdexcept>

#include "telar_base/text/utf8.hpp"

export module telar.base.text;

import telar.base.diagnostics;
import telar.base.memory;

// Owned textual headers stay in this global module fragment only; importers
// reach their names through these declarations instead of including them.
export namespace telar {
using telar::Utf8Validation;
using telar::inspectUtf8;
}
export namespace telar::runtime {
using telar::runtime::utf8Prefix;
}
export namespace telar::runtime::base64 {
using telar::runtime::base64::Padding;
using telar::runtime::base64::alphabet;
using telar::runtime::base64::decode;
using telar::runtime::base64::encode;
using telar::runtime::base64::encoded_pairs;
}
export namespace telar::runtime::control {
using telar::runtime::control::program_name;
using telar::runtime::control::program_version;
using telar::runtime::control::terminfo_name;
}



// Interface: telar_base/text/ascii.cppm
export {
namespace telar::runtime {

inline constexpr char asciiLower(char value) noexcept {
  return value >= 'A' && value <= 'Z' ? value + ('a' - 'A') : value;
}

inline constexpr bool asciiEqualIgnoreCase(std::string_view left, std::string_view right) noexcept {
  if (left.size() != right.size()) {
    return false;
  }
  for (std::size_t index = 0; index < left.size(); ++index) {
    if (asciiLower(left[index]) != asciiLower(right[index])) {
      return false;
    }
  }
  return true;
}

}
}

// Interface: telar_base/text/decimal.cppm
export {
namespace telar::runtime {

template <std::unsigned_integral Integer>
std::optional<Integer> unsignedDecimal(std::string_view text) noexcept {
  if (text.empty() || text.front() == '_' || text.back() == '_') {
    return std::nullopt;
  }

  constexpr Integer base = 10;
  Integer value = 0;
  for (const auto character : text) {
    if (character == '_') {
      continue;
    }
    if (character < '0' || character > '9') {
      return std::nullopt;
    }

    const auto digit = static_cast<Integer>(character - '0');
    if (value > (std::numeric_limits<Integer>::max() - digit) / base) {
      return std::nullopt;
    }

    value = value * base + digit;
  }

  return value;
}

}
}

// Interface: telar_base/text/executable_name.cppm
export {
namespace telar::runtime {

inline constexpr std::string_view withoutExecutableSuffix(std::string_view name) noexcept {
  for (const auto suffix : {std::string_view{".exe"}, std::string_view{".cmd"}, std::string_view{".bat"}, std::string_view{".js"}}) {
    if (name.size() >= suffix.size() && asciiEqualIgnoreCase(name.substr(name.size() - suffix.size()), suffix)) {
      return name.substr(0, name.size() - suffix.size());
    }
  }

  return name;
}

}
}

// Interface: telar_base/text/fields.cppm
export {
namespace telar::runtime {

class TextFields {
public:
  inline explicit TextFields(std::string_view text, std::string_view delimiter) noexcept
      : remaining_(text), delimiter_(delimiter) {}

  inline std::optional<std::string_view> next() noexcept {
    if (finished_) {
      return std::nullopt;
    }
    const auto boundary = remaining_.find(delimiter_);
    const auto field = remaining_.substr(0, boundary);
    if (boundary == std::string_view::npos) {
      finished_ = true;
    } else {
      remaining_.remove_prefix(boundary + delimiter_.size());
    }
    return field;
  }

private:
  std::string_view remaining_;
  std::string_view delimiter_;
  bool finished_ = false;
};

inline tbc::view<std::string_view, tbc::lt::a> trimText(tbc::view<std::string_view, tbc::lt::a> text, std::string_view characters) noexcept {
  const auto start = text.find_first_not_of(characters);
  if (start == std::string_view::npos) {
    return {};
  }
  return text.substr(start, text.find_last_not_of(characters) - start + 1);
}

}
}

// Interface: telar_base/text/hexadecimal.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
void appendLowerHex(String<Memory> &output, std::span<const std::uint8_t> bytes) {
  constexpr std::string_view digits = "0123456789abcdef";
  for (const auto byte : bytes) {
    output += digits[byte >> 4];
    output += digits[byte & 15];
  }
}

}
}

// Interface: telar_base/text/identifier.cppm
export {
namespace telar::runtime {

inline bool validIdentifier(std::string_view name) noexcept {
  if (name.empty() || name.front() == '.' || name.back() == '.' || name.contains("..")) {
    return false;
  }

  return std::ranges::all_of(name, [](unsigned char byte) {
    return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '.' || byte == '-' || byte == '_';
  });
}

}
}

// Interface: telar_base/text/json_error.cppm
export {
namespace telar {

  class JsonError final : public std::exception {
  public:
    inline const char *what() const noexcept override {
      return "Invalid JSON record";
    }
  };

}
}

// Interface: telar_base/text/json.cppm
export {
namespace telar::runtime {

class JsonValue {
public:
  inline explicit JsonValue(std::string_view bytes, unsigned maximum_depth = 32)
      : bytes_(bytes),
        maximum_depth_(maximum_depth) {}

  inline std::string_view encoded() const noexcept {
    return bytes_;
  }

  template <typename Consumer>
  inline void eachElement(Consumer &&consume) const {
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
  inline void eachMember(Consumer &&consume) const {
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

  inline std::optional<JsonValue> field(std::string_view name) const {
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

  inline bool equals(std::string_view expected) const {
    auto input = bytes_;
    return input.starts_with('"') && stringToken(input) == expected;
  }

  inline bool boolean() const noexcept {
    return bytes_ == "true";
  }

  template <Allocator Memory>
  inline void string(String<Memory> &output) const {
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

  inline static JsonValue parse(std::string_view input, unsigned maximum_depth = 32) {
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
  [[noreturn]] inline static void invalid() {
    throw JsonError{};
  }

  inline static void whitespace(std::string_view &input) noexcept {
    const auto end = input.find_first_not_of(" \r\n\t");
    input.remove_prefix(end == std::string_view::npos ? input.size() : end);
  }

  inline static void take(std::string_view &input, char byte) {
    if (!input.starts_with(byte)) {
      invalid();
    }
    input.remove_prefix(1);
  }

  inline static std::uint32_t hex(std::string_view input, std::size_t offset) {
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

  inline static std::string_view stringToken(std::string_view &input) {
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

  inline static void skip(std::string_view &input, unsigned depth, unsigned maximum_depth) {
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

  inline static std::size_t digits(std::string_view &input) noexcept {
    const auto length = input.find_first_not_of("0123456789");
    const auto consumed = length == std::string_view::npos ? input.size() : length;
    input.remove_prefix(consumed);
    return consumed;
  }

  template <Allocator Memory>
  inline static void appendUtf8(String<Memory> &output, std::uint32_t value) {
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
}

// Interface: telar_base/text/json_fields.cppm
export {
namespace telar::runtime {

template <Allocator Memory, std::size_t Count>
class JsonFields {
public:
  // The fields view the object's text and the names, and allocate scratch text, all in region `a`.
  inline explicit JsonFields(tbc::view<Memory &, tbc::lt::a> memory, tbc::view<const JsonValue &, tbc::lt::a> object, tbc::view<const std::array<std::string_view, Count> &, tbc::lt::a> names)
      : names_(names), text_(AllocatorRef<char, Memory>{memory}) {
    object.eachMember([&](const JsonValue &key, const JsonValue &value) {
      key.string(text_);
      const auto index = position(text_);
      if (values_[index]) {
        throw std::invalid_argument{"Duplicate JSON field"};
      }
      values_[index] = value;
    });
  }

  inline const std::optional<JsonValue> &optional(std::string_view name) const {
    return values_[position(name)];
  }

  inline const JsonValue &required(std::string_view name) const {
    const auto &value = optional(name);
    if (!value) {
      throw std::invalid_argument{"Missing JSON field"};
    }
    return *value;
  }

  inline std::string_view string(std::string_view name) {
    required(name).string(text_);
    return text_;
  }

private:
  inline std::size_t position(std::string_view name) const {
    const auto found = std::ranges::find(names_, name);
    if (found == names_.end()) {
      throw std::invalid_argument{"Unknown JSON field"};
    }
    return static_cast<std::size_t>(found - names_.begin());
  }

  tbc::view<std::array<std::string_view, Count>, tbc::lt::a> names_;
  tbc::view<std::array<std::optional<JsonValue>, Count>, tbc::lt::a> values_;
  tbc::view<String<Memory>, tbc::lt::a> text_;
};

template <Allocator Memory, std::size_t Count>
JsonFields(Memory &memory, const JsonValue &object, const std::array<std::string_view, Count> &names) -> JsonFields<Memory, Count>;

}
}

// Interface: telar_base/text/json_node.cppm
export {
namespace telar::runtime {

enum class JsonKind { object,
                      array,
                      string,
                      literal };

template <Allocator Memory>
class JsonNode {
public:
  // A node allocates its text and children from the allocator in region `a`.
  inline explicit JsonNode(tbc::view<Memory &, tbc::lt::a> memory, JsonKind kind = JsonKind::object)
      : name_(AllocatorRef<char, Memory>{memory}), text_(AllocatorRef<char, Memory>{memory}), children_(AllocatorRef<JsonNode, Memory>{memory}), kind_(kind) {}

  inline static tbc::view<JsonNode, tbc::lt::a> parse(tbc::view<Memory &, tbc::lt::a> memory, std::string_view source) {
    if (inspectUtf8(source) != Utf8Validation::valid) {
      throw JsonError{};
    }
    return fromValue(memory, JsonValue::parse(source, maximum_depth));
  }

  inline JsonKind kind() const noexcept { return kind_; }
  inline std::string_view text() const noexcept { return text_; }
  inline std::span<JsonNode> children() noexcept { return children_; }
  inline std::span<const JsonNode> children() const noexcept { return children_; }

  inline JsonNode *find(std::string_view name) noexcept {
    if (kind_ != JsonKind::object) {
      return nullptr;
    }

    const auto found = std::ranges::find_if(children_, [name](const auto &child) { return child.name_ == name; });
    return found == children_.end() ? nullptr : &*found;
  }

  inline const JsonNode *find(std::string_view name) const noexcept {
    return const_cast<JsonNode *>(this)->find(name);
  }

  inline JsonNode &ensure(std::string_view name, JsonKind kind) {
    if (kind_ != JsonKind::object) {
      throw std::invalid_argument{"Expected JSON object"};
    }
    if (auto *existing = find(name)) {
      if (existing->kind_ != kind) {
        throw std::invalid_argument{"Unexpected JSON field type"};
      }

      return *existing;
    }

    JsonNode child{memory(), kind};
    child.name_ = name;
    children_.push_back(std::move(child));
    return children_.back();
  }

  inline void setString(std::string_view name, std::string_view value) {
    auto &child = ensure(name, JsonKind::string);
    child.text_ = value;
  }

  inline void setLiteral(std::string_view name, std::string_view value) {
    auto &child = ensure(name, JsonKind::literal);
    child.text_ = value;
  }

  inline void append(JsonNode child) {
    if (kind_ != JsonKind::array) {
      throw std::invalid_argument{"Expected JSON array"};
    }

    children_.push_back(std::move(child));
  }

  inline void erase(std::size_t index) {
    children_.erase(children_.begin() + index);
  }

  inline void remove(std::string_view name) {
    std::erase_if(children_, [name](const auto &child) { return child.name_ == name; });
  }

  inline String<Memory> format() const {
    String<Memory> output{AllocatorRef<char, Memory>{memory()}};
    appendFormatted(output, 0);
    output += '\n';
    return output;
  }

private:
  static constexpr unsigned maximum_depth = 256;
  static constexpr unsigned indentation = 2;

  inline tbc::view<Memory &, tbc::lt::a> memory() const noexcept { return text_.get_allocator().memory(); }

  inline static tbc::view<JsonNode, tbc::lt::a> fromValue(tbc::view<Memory &, tbc::lt::a> memory, JsonValue value) {
    const auto encoded = value.encoded();
    const auto kind = encoded.starts_with('{') ? JsonKind::object : encoded.starts_with('[') ? JsonKind::array
                                                                : encoded.starts_with('"')   ? JsonKind::string
                                                                                             : JsonKind::literal;
    JsonNode node{memory, kind};
    if (kind == JsonKind::object) {
      value.eachMember([&](JsonValue key, JsonValue item) {
        auto child = fromValue(memory, item);
        key.string(child.name_);
        node.children_.push_back(std::move(child));
      });

      Vector<std::string_view, Memory> names{AllocatorRef<std::string_view, Memory>{memory}};
      names.reserve(node.children_.size());
      for (const auto &child : node.children_) {
        names.push_back(child.name_);
      }
      std::ranges::sort(names);
      if (std::adjacent_find(names.begin(), names.end()) != names.end()) {
        throw std::invalid_argument{"Duplicate JSON field"};
      }
    } else if (kind == JsonKind::array) {
      value.eachElement([&](JsonValue item) { node.children_.push_back(fromValue(memory, item)); });
    } else if (kind == JsonKind::string) {
      value.string(node.text_);
    } else {
      node.text_ = encoded;
    }

    return node;
  }

  inline void appendFormatted(String<Memory> &output, unsigned depth) const {
    if (kind_ == JsonKind::string) {
      appendJsonString(output, text_);
      return;
    }
    if (kind_ == JsonKind::literal) {
      output += text_;
      return;
    }

    output += kind_ == JsonKind::object ? '{' : '[';
    for (std::size_t index = 0; index < children_.size(); ++index) {
      output += index == 0 ? "\n" : ",\n";
      output.append((depth + 1) * indentation, ' ');
      const auto &child = children_[index];
      if (kind_ == JsonKind::object) {
        appendJsonString(output, child.name_);
        output += ": ";
      }

      child.appendFormatted(output, depth + 1);
    }
    if (!children_.empty()) {
      output += '\n';
      output.append(depth * indentation, ' ');
    }

    output += kind_ == JsonKind::object ? '}' : ']';
  }

  tbc::view<String<Memory>, tbc::lt::a> name_;
  tbc::view<String<Memory>, tbc::lt::a> text_;
  tbc::view<Vector<JsonNode, Memory>, tbc::lt::a> children_;
  JsonKind kind_;
};

}
}

// Interface: telar_base/text/schema_version.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class SchemaVersion {
public:
  inline static bool isOne(Memory &memory, const JsonValue &value) {
    String<Memory> text{AllocatorRef<char, Memory>{memory}};
    if (value.encoded().starts_with('"')) {
      value.string(text);
    } else {
      text = value.encoded();
    }
    return SchemaVersion{memory}.parse(text);
  }

private:
  inline explicit SchemaVersion(Memory &memory) : digits_(AllocatorRef<char, Memory>{memory}) {}

  inline bool parse(std::string_view text) {
    const bool floating = text.find_first_of(".eE") != std::string_view::npos;
    if (text.starts_with('+')) {
      text.remove_prefix(1);
    }
    if (text.empty() || text.starts_with('-') || text.front() == '_' || text.back() == '_') {
      return false;
    }

    const bool hexadecimal = floating && (text.starts_with("0x") || text.starts_with("0X"));
    if (hexadecimal) {
      text.remove_prefix(2);
    }
    const unsigned base = hexadecimal ? 16 : 10;
    const auto exponent_at = text.find_first_of(hexadecimal ? "pP" : "eE");
    const auto mantissa = text.substr(0, exponent_at);
    if (!readMantissa(mantissa, base, floating)) {
      return false;
    }

    std::int64_t exponent = 0;
    if (exponent_at != std::string_view::npos && (!floating || !readExponent(text.substr(exponent_at + 1), exponent))) {
      return false;
    }
    const auto first = digits_.find_first_not_of('0');
    if (first == String<Memory>::npos) {
      return false;
    }

    exponent += integer_digits_ - static_cast<std::int64_t>(first);
    if (hexadecimal && (digits_.size() - (first / 4) * 4) / 4 > 32) {
      truncateHexFallback();
    }
    const auto significant = std::string_view{digits_}.substr(first);
    if (!floating) {
      return exponent == 1 && compare(significant, "1") == 0;
    }

    // Zig coerces JSON versions through binary128. Compare its exact rounding
    // interval around one; double precision would accept different versions.
    const auto lower = hexadecimal ? std::string_view{binary_lower.data(), binary_lower.size()} : decimal_lower;
    const auto upper = hexadecimal ? std::string_view{binary_upper.data(), binary_upper.size()} : decimal_upper;
    if (exponent == 0) {
      return compare(significant, lower) >= 0;
    }
    return exponent == 1 && compare(significant, upper) <= 0;
  }

  inline void truncateHexFallback() {
    // The reference's long-hex fallback stops at a decimal coefficient of
    // 10^31, so its discarded tail cannot participate in binary128 rounding.
    __uint128_t coefficient = 0;
    std::size_t consumed = 0;
    while (consumed < digits_.size() && coefficient < hex_fallback_coefficient) {
      for (unsigned bit = 0; bit < 4; ++bit) {
        coefficient = coefficient * 2 + static_cast<unsigned>(digits_[consumed++] - '0');
      }
    }
    digits_.resize(consumed);
  }

  inline bool readMantissa(std::string_view text, unsigned base, bool floating) {
    bool point = false;
    for (std::size_t index = 0; index < text.size(); ++index) {
      const char byte = text[index];
      if (byte == '_') {
        if (index == 0 || index + 1 == text.size() || (floating && (digit(text[index - 1]) >= base || digit(text[index + 1]) >= base))) {
          return false;
        }
        continue;
      }
      if (byte == '.' && floating && !point) {
        point = true;
        continue;
      }
      const auto value = digit(byte);
      if (value >= base) {
        return false;
      }

      if (base == 16) {
        for (unsigned shift = 4; shift != 0; --shift) {
          digits_ += static_cast<char>('0' + ((value >> (shift - 1)) & 1));
        }
      } else {
        digits_ += byte;
      }
      if (!point) {
        integer_digits_ += base == 16 ? 4 : 1;
      }
    }
    return !digits_.empty();
  }

  inline static bool readExponent(std::string_view text, std::int64_t &value) noexcept {
    const bool negative = text.starts_with('-');
    if (negative || text.starts_with('+')) {
      text.remove_prefix(1);
    }
    if (text.empty()) {
      return false;
    }

    for (std::size_t index = 0; index < text.size(); ++index) {
      if (text[index] == '_') {
        if (index == 0 || index + 1 == text.size() || digit(text[index - 1]) >= 10 || digit(text[index + 1]) >= 10) {
          return false;
        }
        continue;
      }
      const auto number = digit(text[index]);
      if (number >= 10) {
        return false;
      }
      value = std::min(exponent_limit, value * 10 + number);
    }
    value = negative ? -value : value;
    return true;
  }

  inline static unsigned digit(char byte) noexcept {
    if (byte >= '0' && byte <= '9') {
      return static_cast<unsigned>(byte - '0');
    }
    if (byte >= 'a' && byte <= 'f') {
      return static_cast<unsigned>(byte - 'a' + 10);
    }
    if (byte >= 'A' && byte <= 'F') {
      return static_cast<unsigned>(byte - 'A' + 10);
    }
    return 16;
  }

  inline static int compare(std::string_view left, std::string_view right) noexcept {
    for (std::size_t index = 0; index < std::max(left.size(), right.size()); ++index) {
      const auto first = index < left.size() ? left[index] : '0';
      const auto second = index < right.size() ? right[index] : '0';
      if (first != second) {
        return first < second ? -1 : 1;
      }
    }
    return 0;
  }

  static constexpr std::int64_t exponent_limit = 1'000'000;
  static constexpr auto hex_fallback_coefficient = [] {
    __uint128_t value = 1;
    for (unsigned power = 0; power < 31; ++power) {
      value *= 10;
    }
    return value;
  }();
  static constexpr std::string_view decimal_lower = "999999999999999999999999999999999951851751390319103673600551435376817036547458794615295119001530110836029052734375";
  static constexpr std::string_view decimal_upper = "100000000000000000000000000000000009629649721936179265279889712924636592690508241076940976199693977832794189453125";
  static constexpr auto binary_lower = [] {
    std::array<char, 114> digits;
    digits.fill('1');
    return digits;
  }();
  static constexpr auto binary_upper = [] {
    std::array<char, 114> digits;
    digits.fill('0');
    digits.front() = '1';
    digits.back() = '1';
    return digits;
  }();
  String<Memory> digits_;
  std::int64_t integer_digits_ = 0;
};

}
}
