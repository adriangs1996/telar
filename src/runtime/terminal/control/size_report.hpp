#pragma once

#include "reply.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <cassert>

namespace telar::runtime::control {

enum class SizeReport : unsigned {
  pixels = 4,
  cell = 6,
  text = 8,
  screen = 9,
  event = 48,
};

template <SizeReport Kind, Allocator Memory>
void sizeReport(Reply<Memory> &reply, TerminalSize size) {
  // Two uint16 dimensions and two uint32 products fit, including separators.
  constexpr std::size_t maximum_reply_bytes = 48;
  static_assert(sizeof(size.rows) == sizeof(std::uint16_t));
  static_assert(sizeof(size.cols) == sizeof(std::uint16_t));
  static_assert(sizeof(size.cell_height_px) == sizeof(std::uint16_t));
  static_assert(sizeof(size.cell_width_px) == sizeof(std::uint16_t));
  std::array<char, maximum_reply_bytes> encoded;
  constexpr std::string_view prefix = Kind == SizeReport::pixels ? "\x1b[4;" : Kind == SizeReport::cell ? "\x1b[6;" : Kind == SizeReport::text ? "\x1b[8;" : Kind == SizeReport::screen ? "\x1b[9;" : "\x1b[48;";
  auto *next = std::copy(prefix.begin(), prefix.end(), encoded.data());
  const auto number = [&](std::uint32_t value) {
    const auto result = std::to_chars(next, encoded.data() + encoded.size(), value);
    assert(result.ec == std::errc{});
    next = result.ptr;
  };

  if constexpr (Kind == SizeReport::pixels) {
    number(static_cast<std::uint32_t>(size.rows) * size.cell_height_px);
    *next++ = ';';
    number(static_cast<std::uint32_t>(size.cols) * size.cell_width_px);
  } else if constexpr (Kind == SizeReport::cell) {
    number(size.cell_height_px);
    *next++ = ';';
    number(size.cell_width_px);
  } else {
    number(size.rows);
    *next++ = ';';
    number(size.cols);
    if constexpr (Kind == SizeReport::event) {
      *next++ = ';';
      number(static_cast<std::uint32_t>(size.rows) * size.cell_height_px);
      *next++ = ';';
      number(static_cast<std::uint32_t>(size.cols) * size.cell_width_px);
    }
  }
  *next++ = 't';
  reply.append({encoded.data(), static_cast<std::size_t>(next - encoded.data())});
}

}
