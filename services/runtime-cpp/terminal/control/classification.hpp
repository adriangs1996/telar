#pragma once

#include "parameters.hpp"
#include "sequence.hpp"
#include "../../graphics/kitty_control.hpp"

namespace telar::runtime::control {

inline bool nativeOsc(unsigned number) noexcept {
  return number == 4 || number == 5 || (number >= 10 && number <= 21) || number == 52 || (number >= 104 && number <= 119) || number == 5522;
}

inline std::optional<unsigned> decimal(std::string_view text) noexcept {
  if (text.empty()) {
    return std::nullopt;
  }

  unsigned value = 0;
  for (const auto byte : text) {
    if (byte < '0' || byte > '9' || value > (UINT16_MAX - static_cast<unsigned>(byte - '0')) / 10) {
      return std::nullopt;
    }
    value = value * 10 + static_cast<unsigned>(byte - '0');
  }
  return value;
}

inline bool graphicsQuery(std::string_view body) noexcept {
  if (!body.starts_with('G')) {
    return false;
  }
  const auto separator = body.find(';');
  auto remaining = body.substr(1, separator == std::string_view::npos ? separator : separator - 1);
  bool query = false;
  while (!remaining.empty()) {
    const auto comma = remaining.find(',');
    const auto field = remaining.substr(0, comma);
    if (field.starts_with("a=")) {
      auto value = field.substr(2);
      if (value.starts_with('+')) {
        value.remove_prefix(1);
      }
      query = value == "q" || kittyUnsigned<std::uint32_t>(value) == static_cast<std::uint32_t>('q');
    }
    remaining = comma == std::string_view::npos ? std::string_view{} : remaining.substr(comma + 1);
  }
  return query;
}

inline bool streamable(Sequence sequence) noexcept {
  const auto body = sequence.body();
  switch (sequence.kind) {
  case Kind::osc: {
    const auto number = decimal(body.substr(0, body.find(';')));
    return !number || !nativeOsc(*number);
  }
  case Kind::dcs:
    return !body.ends_with("+q") && !body.ends_with("$q");
  case Kind::apc:
    if (!body.starts_with('G')) {
      return !body.starts_with("25a1;");
    }
    return !graphicsQuery(body);
  default:
    return false;
  }
}

inline bool query(Sequence sequence) noexcept {
  const auto body = sequence.body();
  if (sequence.kind == Kind::apc) {
    return graphicsQuery(body) || body.starts_with("25a1;");
  }
  if (sequence.kind == Kind::dcs) {
    const auto end = body.find_first_of("@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~");
    if (end == std::string_view::npos) {
      return false;
    }
    const auto header = Parameters::parse(body.substr(0, end + 1));
    return header && header->final == 'q' && (header->modifiers() == "+" || header->modifiers() == "$");
  }
  if (sequence.kind == Kind::osc) {
    const auto operation = decimal(body.substr(0, body.find(';')));
    return operation && nativeOsc(*operation);
  }
  if (sequence.kind == Kind::escape) {
    return body == "Z";
  }

  const auto header = Parameters::parse(body);
  if (!header) {
    return false;
  }
  const auto modifiers = header->modifiers();
  switch (header->final) {
  case 'c': return true;
  case 'n': return modifiers.empty() || modifiers == "?";
  case 'q': return modifiers == ">";
  case 'p': return modifiers == "$" || modifiers == "?$";
  case 'u': return modifiers == "?";
  case 't': return modifiers.empty() && header->count == 1 && header->values[0] >= 14 && header->values[0] <= 21;
  case 'y': return modifiers == "*" || modifiers == "#";
  default: return false;
  }
}

}
