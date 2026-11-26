module;
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
  [[tbc::generic]] void cursorReport(Reply<Memory>& reply, Position position, bool extended) {
    constexpr std::size_t maximum_cursor_reply = 32;
    ds::Array<char, maximum_cursor_reply> encoded{};
    // One mutable borrow of the buffer, which `next` walks.
    const std::span<char> output{encoded.dataMut(), encoded.size()};
    auto* next = output.data();

    *next++ = '\x1b';
    *next++ = '[';
    if (extended) {
      *next++ = '?';
    }

    const auto row = std::to_chars(next, output.data() + output.size(), static_cast<unsigned>(position.row) + 1);

    // to_chars reports success as the errc of value 0, which names no error.
    TELAR_ASSERT(std::to_underlying(row.ec) == 0);
    next = row.ptr;
    *next++ = ';';
    const auto column = std::to_chars(next, output.data() + output.size(), static_cast<unsigned>(position.column) + 1);

    TELAR_ASSERT(std::to_underlying(column.ec) == 0);
    next = column.ptr;
    if (extended) {
      *next++ = ';';
      *next++ = '1';
    }

    *next++ = 'R';
    reply.append({output.data(), static_cast<std::size_t>(next - output.data())});
  }

}
