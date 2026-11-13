#pragma once

#include "reply.hpp"
#include "vt_state.hpp"
#include <array>
#include <cassert>
#include <charconv>

namespace telar::runtime::control {

template <Allocator Memory>
void cursorReport(Reply<Memory> &reply, Position position, bool extended) {
  constexpr std::size_t maximum_cursor_reply = 32;
  std::array<char, maximum_cursor_reply> encoded;
  auto *next = encoded.data();
  *next++ = '\x1b';
  *next++ = '[';
  if (extended) {
    *next++ = '?';
  }

  const auto row = std::to_chars(next, encoded.data() + encoded.size(), static_cast<unsigned>(position.row) + 1);
  assert(row.ec == std::errc{});
  next = row.ptr;
  *next++ = ';';
  const auto column = std::to_chars(next, encoded.data() + encoded.size(), static_cast<unsigned>(position.column) + 1);
  assert(column.ec == std::errc{});
  next = column.ptr;
  if (extended) {
    *next++ = ';';
    *next++ = '1';
  }
  *next++ = 'R';
  reply.append({encoded.data(), static_cast<std::size_t>(next - encoded.data())});
}

}
