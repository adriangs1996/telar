#pragma once

#include "json_text.hpp"
#include "telar_base/text/json.hpp"
#include <cmath>
#include <cstdlib>

namespace telar::runtime::cli::window {

template <Allocator Memory>
void appendJsonNumber(String<Memory> &output, std::string_view encoded) {
  if (encoded.find_first_of(".eE") == std::string_view::npos) {
    output += encoded;
    return;
  }

  double value = 0;
  const auto parsed = std::from_chars(encoded.data(), encoded.data() + encoded.size(), value);
  if (parsed.ec == std::errc::result_out_of_range) {
    const String<Memory> terminated{encoded, output.get_allocator()};
    value = std::strtod(terminated.c_str(), nullptr);
  }

  if (!std::isfinite(value)) {
    output += encoded;
    return;
  }

  constexpr std::size_t maximum_float_bytes = 64;
  std::array<char, maximum_float_bytes> buffer;
  const auto formatted = std::to_chars(buffer.data(), buffer.data() + buffer.size(), value);
  const std::string_view number{buffer.data(), formatted.ptr};
  const auto exponent_at = number.find('e');
  if (exponent_at == std::string_view::npos) {
    output += number;
    return;
  }

  auto mantissa = number.substr(0, exponent_at);
  auto exponent_text = number.substr(exponent_at + 1);
  if (exponent_text.starts_with('+')) {
    exponent_text.remove_prefix(1);
  }

  int exponent = 0;
  std::from_chars(exponent_text.data(), exponent_text.data() + exponent_text.size(), exponent);
  if (mantissa.starts_with('-')) {
    output += '-';
    mantissa.remove_prefix(1);
  }

  const auto dot = mantissa.find('.');
  const int decimal_position = static_cast<int>(dot == std::string_view::npos ? mantissa.size() : dot) + exponent;
  String<Memory> digits{output.get_allocator()};
  for (const auto byte : mantissa) {
    if (byte != '.') {
      digits += byte;
    }
  }

  if (decimal_position <= 0) {
    output += "0.";
    output.append(static_cast<std::size_t>(-decimal_position), '0');
    output += digits;
  } else if (static_cast<std::size_t>(decimal_position) >= digits.size()) {
    output += digits;
    output.append(static_cast<std::size_t>(decimal_position) - digits.size(), '0');
  } else {
    output.append(digits.data(), static_cast<std::size_t>(decimal_position));
    output += '.';
    output.append(digits.data() + decimal_position, digits.size() - static_cast<std::size_t>(decimal_position));
  }
}

// Re-encode parsed JSON with Zig's string escapes and two-space indentation.
template <Allocator Memory>
void appendJson(String<Memory> &output, const JsonValue &value, bool pretty, unsigned depth = 0) {
  const auto encoded = value.encoded();
  if (encoded.starts_with('"')) {
    String<Memory> text{output.get_allocator()};
    value.string(text);
    appendJsonText(output, text, JsonEscapes::standard);
    return;
  }

  if (!encoded.starts_with('{') && !encoded.starts_with('[')) {
    if (encoded == "true" || encoded == "false" || encoded == "null") {
      output += encoded;
    } else {
      appendJsonNumber(output, encoded);
    }

    return;
  }

  const bool object = encoded.starts_with('{');
  output += object ? '{' : '[';
  std::size_t count = 0;
  const auto separator = [&] {
    if (count++ != 0) {
      output += ',';
    }
    if (pretty) {
      output += '\n';
      output.append((depth + 1) * 2, ' ');
    }
  };
  if (object) {
    value.eachMember([&](const JsonValue &key, const JsonValue &member) {
      separator();
      appendJson(output, key, false);
      output += pretty ? ": " : ":";
      appendJson(output, member, pretty, depth + 1);
    });
  } else {
    value.eachElement([&](const JsonValue &member) {
      separator();
      appendJson(output, member, pretty, depth + 1);
    });
  }

  if (pretty && count != 0) {
    output += '\n';
    output.append(depth * 2, ' ');
  }

  output += object ? '}' : ']';
}

}
