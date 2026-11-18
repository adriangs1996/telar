module;
#include "tbc/annotations.hpp"
#include "telar_base/diagnostics/config.hpp"

export module telar.runtime.terminal.control:cursor_report;

import std;
import telar.base.memory.allocators;
import :reply;
import :vt_state;
import telar.base.ds;

export namespace telar::runtime::control {

  // Generic over the caller's allocator, so it stays here.
  template <Allocator Memory>
  TBC_GENERIC void cursorReport(Reply<Memory>& reply, Position position, bool extended) {
    constexpr std::size_t maximum_cursor_reply = 32;
    ds::Array<char, maximum_cursor_reply> encoded;
    auto* next = encoded.dataMut();

    *next++ = '\x1b';
    *next++ = '[';
    if (extended) {
      *next++ = '?';
    }

    const auto row = std::to_chars(next, encoded.dataMut() + encoded.size(), static_cast<unsigned>(position.row) + 1);

    TELAR_ASSERT(row.ec == std::errc{});
    next = row.ptr;
    *next++ = ';';
    const auto column = std::to_chars(next, encoded.dataMut() + encoded.size(), static_cast<unsigned>(position.column) + 1);

    TELAR_ASSERT(column.ec == std::errc{});
    next = column.ptr;
    if (extended) {
      *next++ = ';';
      *next++ = '1';
    }

    *next++ = 'R';
    reply.append({encoded.data(), static_cast<std::size_t>(next - encoded.data())});
  }

}
