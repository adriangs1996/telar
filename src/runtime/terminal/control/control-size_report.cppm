module;
#include "tbc/annotations.hpp"
#include "telar_base/diagnostics/config.hpp"

export module telar.runtime.terminal.control:size_report;

import std;
import telar.base.memory.allocators;
import telar.vocabulary;
import :reply;
import telar.base.ds;

export namespace telar::runtime::control {

  enum class SizeReport : std::uint8_t {
    pixels = 4,
    cell = 6,
    text = 8,
    screen = 9,
    event = 48,
  };

  // The CSI that begins a report: its number is the request's.
  constexpr std::string_view sizeReportPrefix(SizeReport kind) noexcept {
    switch (kind) {
    case SizeReport::pixels:
      return "\x1b[4;";
    case SizeReport::cell:
      return "\x1b[6;";
    case SizeReport::text:
      return "\x1b[8;";
    case SizeReport::screen:
      return "\x1b[9;";
    case SizeReport::event:
      return "\x1b[48;";
    }

    // A value outside the enum reports as an event.
    return "\x1b[48;";
  }

  // Generic over the caller's allocator, so it stays here.
  template <SizeReport Kind, Allocator Memory>
  TBC_GENERIC void sizeReport(Reply<Memory>& reply, TerminalSize size) {
    // Two uint16 dimensions and two uint32 products fit, including separators.
    constexpr std::size_t maximum_reply_bytes = 48;
    static_assert(sizeof(size.rows) == sizeof(std::uint16_t));
    static_assert(sizeof(size.cols) == sizeof(std::uint16_t));
    static_assert(sizeof(size.cell_height_px) == sizeof(std::uint16_t));
    static_assert(sizeof(size.cell_width_px) == sizeof(std::uint16_t));
    ds::Array<char, maximum_reply_bytes> encoded{};
    constexpr std::string_view prefix = sizeReportPrefix(Kind);
    // One mutable borrow of the buffer, which `next` walks.
    const std::span<char> output{encoded.dataMut(), encoded.size()};
    auto* next = std::ranges::copy(prefix, output.data()).out;
    const auto number = [&](std::uint32_t value) {
      const auto result = std::to_chars(next, output.data() + output.size(), value);

      // to_chars reports success as the errc of value 0, which names no error.
      TELAR_ASSERT(std::to_underlying(result.ec) == 0);
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
    reply.append({output.data(), static_cast<std::size_t>(next - output.data())});
  }

}
