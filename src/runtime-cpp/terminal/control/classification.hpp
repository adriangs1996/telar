#pragma once

#include "parameters.hpp"
#include "sequence.hpp"
#include "graphics_header.hpp"
#include "../../graphics/kitty_control.hpp"
#include <charconv>

namespace telar::runtime::control {

inline constexpr std::array<std::uint16_t, 5> desktop_modes{1004, 2031, 2033, 2048, 5522};

template <typename Writer>
void forwardPrivateMode(std::uint16_t mode, char final, Writer &&write) {
  std::array<char, 16> command;
  constexpr std::string_view prefix = "\x1b[?";
  std::copy(prefix.begin(), prefix.end(), command.begin());
  const auto number = std::to_chars(command.data() + prefix.size(), command.data() + command.size() - 1, mode);
  *number.ptr = final;
  write(std::span<const std::uint8_t>{reinterpret_cast<const std::uint8_t *>(command.data()), static_cast<std::size_t>(number.ptr + 1 - command.data())});
}

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

inline std::optional<unsigned> oscOperation(std::string_view text) noexcept {
  if (text.size() > 1 && text.front() == '0') {
    return std::nullopt;
  }
  return decimal(text);
}

inline bool graphicsQuery(std::string_view body) noexcept {
  if (!body.starts_with('G')) {
    return false;
  }
  const auto separator = body.find(';');
  const auto header = body.substr(1, separator == std::string_view::npos ? separator : separator - 1);
  bool query = false;
  GraphicsHeader::scan(header, separator != std::string_view::npos, [&](std::uint8_t key, std::string_view text) noexcept {
    if (key == 'a') {
      query = GraphicsHeader::value(key, text) == static_cast<std::uint32_t>('q');
    }
    return true;
  });
  return query;
}

inline bool streamable(Sequence sequence) noexcept {
  const auto body = sequence.body();
  switch (sequence.kind) {
  case Kind::osc: {
    const auto number = oscOperation(body.substr(0, body.find(';')));
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
    const auto operation = oscOperation(body.substr(0, body.find(';')));
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
