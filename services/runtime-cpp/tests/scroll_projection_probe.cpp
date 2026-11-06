#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_base/memory/allocator.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "../diagnostics/line.hpp"
#include "telar_base/diagnostics/config.hpp"
#include "telar_platform/trace.hpp"
#include "cell_layout.hpp"
#include "../terminal/ghostty_handle.hpp"
#include <cstring>
#include <tuple>
#include "../graphics/kitty_framing.hpp"
#include <array>
#include <variant>
#include "../graphics/media_budget.hpp"
#include "../graphics/kitty_control.hpp"
#include <cstddef>
#include <cstdint>
#include <span>
#include <algorithm>
#include "../graphics/child_file.hpp"
#include "telar_platform/graphics/child_shared_memory.hpp"
#include <utility>
#include "../terminal/control/classification.hpp"
#include "../terminal/control/parser.hpp"
#include "../terminal/pty_response_queue.hpp"
#include <stdexcept>
#include "../graphics/temporary_path.hpp"
#include <charconv>
#include "../terminal/ghostty_allocator.hpp"
#include <optional>
#include "telar_config/graphics/limits.hpp"
#include <limits>
#include "telar_platform/file_descriptor.hpp"
#include "telar_platform/random_bytes.hpp"
#include "telar_platform/mapped_region.hpp"
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <string_view>
#include <sys/mman.h>
#include <atomic>
#include "../terminal/control/engine.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "../terminal/graphics_cursor.hpp"
#include <cassert>
#include "check.hpp"
#include <chrono>
#include <exception>
#include <ghostty/vt.h>
#include <string>

#include "tests/check.hpp"

#ifdef TELAR_SCROLL_CENSUS

import telar.runtime.terminal.text_reader;

extern "C" std::uint64_t scroll_census_count;
#endif

using namespace telar;
using namespace telar::runtime;

namespace {
constexpr std::uint16_t columns = 82;
constexpr std::uint16_t rows = 21;
constexpr std::uint32_t history_rows = 4096;
constexpr std::size_t warmup = 100;
constexpr std::uint16_t cell_width = 18;
constexpr std::uint16_t cell_height = 40;
constexpr std::size_t decode_capacity = 256U * 1024U;
constexpr std::uint32_t scroll_start = 1000;
constexpr std::uint32_t scroll_step = 3;
constexpr std::uint32_t verify_half_cycle = 60;
constexpr std::uint32_t benchmark_half_cycle = 100;
constexpr std::uint32_t explicit_link_ids = 7;
constexpr std::uint32_t unique_uris = 17;
constexpr std::size_t row_label_space = 8;
constexpr TerminalSize original_size{.cols = columns, .rows = rows, .cell_width_px = cell_width, .cell_height_px = cell_height};
constexpr TerminalSize smaller_size{.cols = 70, .rows = 17, .cell_width_px = cell_width, .cell_height_px = cell_height};

std::span<const Byte> bytes(std::string_view text) {
  return byteView(text);
}

template <typename Value>
void record(std::span<const Value> value) {
  const auto size = static_cast<std::uint64_t>(value.size_bytes());
  check(std::fwrite(&size, sizeof(size), 1, stdout) == 1);
  check(std::fwrite(value.data(), 1, value.size_bytes(), stdout) == value.size_bytes());
}

struct Fixture {
  SystemAllocator memory;
  Terminal<SystemAllocator> terminal{memory, original_size, TerminalPurpose::separate_media};
  FrameSync<SystemAllocator> full{memory, 1};
  FrameSync<SystemAllocator> delta{memory, 1};
  std::array<Byte, decode_capacity> decode{};
  std::uint64_t observed = 0;
  std::uint64_t full_frame_id = 0;
  std::uint64_t delta_frame_id = 0;
  bool internal_revisions;

  explicit Fixture(bool rich, bool record_internal_revisions = true)
      : internal_revisions(record_internal_revisions) {
    std::string text;
    for (std::uint32_t row = 0; row < history_rows; ++row) {
      if (row != 0) {
        text += "\r\n";
      }

      text += std::to_string(row);
      if (rich) {
        text += " \x1b[1;3;4;38;5;2mstyled\x1b[0m e\xcc\x81 \xe7\x95\x8c ";
        text += "\x1b]8;id=" + std::to_string(row % explicit_link_ids) + ";https://example.test/" + std::to_string(row % unique_uris) + "\x1b\\link\x1b]8;;\x1b\\";
      } else {
        text.append(columns - row_label_space, 'x');
      }
    }

    terminal.feed(bytes(text));
    terminal.refresh();
    check(terminal.screen.scroll.total_rows == history_rows);
  }

  void frame(FrameSync<SystemAllocator> &sync, bool emit) {
    const auto payload = sync.prepare(terminal.screen);
    if (emit) {
      record(payload);
    }

    if (!payload.empty()) {
      const auto identity = &sync == &full ? ++full_frame_id : ++delta_frame_id;
      if (emit) {
        DecodeStorage storage{decode};
        const auto value = Codec::decode<PaneFrame>(payload, storage);
        value.validate();
        check(value.frame_id == identity);
      }

      observed += payload.size() + identity;
      check(sync.acknowledge(identity));
    }
  }

  void publish(bool emit, bool restore_viewport = true) {
    terminal.refresh();
    if (emit) {
      check(!terminal.dirty());
      const auto revision = terminal.screen.revision;
      terminal.refresh();
      check(!terminal.dirty() && terminal.screen.revision == revision);
      full.requestSnapshot();
      frame(full, true);
      record(std::span<const ScreenCell>{terminal.screen.cells});
      if (internal_revisions) {
        record(std::span<const std::uint64_t>{terminal.screen.row_revisions});
      }
    }

    frame(delta, emit);
    if (restore_viewport) {
      terminal.scrollToBottom();
    }
  }

  void scroll(std::uint32_t offset, bool emit) {
    terminal.scrollTo(offset);
    if (emit) {
      check(terminal.dirty());
    }

    publish(emit);
    if (emit) {
      terminal.scrollTo(offset);
      publish(true);
    }
  }
};

void verify(bool internal_revisions) {
  for (const bool rich : {false, true}) {
    Fixture fixture{rich, internal_revisions};
    fixture.publish(true);
    for (const auto offset : {4000U, 3997U, 3994U, 3994U, 3997U, 4000U, 0U, 3U, 2000U, 4075U, 4096U}) {
      fixture.scroll(offset, true);
    }

    for (std::uint32_t step = 0; step < verify_half_cycle * 2; ++step) {
      fixture.scroll(scroll_start + (scroll_step * (step < verify_half_cycle ? step : (verify_half_cycle * 2) - 1 - step)), true);
    }

    fixture.terminal.scrollToBottom();
    fixture.publish(true);
    fixture.terminal.feed(bytes("\x1b[1;1Hchanged cached row"));
    check(fixture.terminal.dirty());
    fixture.terminal.scrollTo(0);
    fixture.terminal.scrollToBottom();
    fixture.scroll(history_rows - rows - scroll_step, true);
    fixture.terminal.feed(bytes("\x1b[38;2;20;"));
    fixture.scroll(scroll_start, true);
    fixture.terminal.feed(bytes("40;60mcompleted control\x1b[0m"));
    fixture.scroll(scroll_start + scroll_step, true);

    fixture.terminal.configureColors({.foreground = std::array<Byte, 3>{90, 70, 50}, .background = std::array<Byte, 3>{3, 5, 7}, .palette = std::array<Byte, 48>{}});
    check(fixture.terminal.dirty());
    fixture.terminal.scrollTo(0);
    fixture.terminal.scrollToBottom();
    fixture.scroll(1003, true);
    fixture.terminal.configureCursorColor(std::array<Byte, 3>{1, 2, 3});
    fixture.scroll(1006, true);
    fixture.terminal.feed(bytes("\x1b]4;2;rgb:aa/bb/cc\x1b\\\x1b]10;rgb:10/20/30\x1b\\\r\nnew output\r\n"));
    fixture.scroll(1009, true);
    fixture.terminal.resize(smaller_size);
    fixture.scroll(1012, true);
    fixture.terminal.resize(original_size);
    fixture.scroll(1015, true);
    fixture.terminal.feed(bytes("\x1b[?1049h\x1b[2Jalternate"));
    fixture.scroll(0, true);
    fixture.terminal.feed(bytes("\x1b[?1049l"));
    fixture.scroll(1018, true);
    auto *const exposed = fixture.terminal.handle();
    fixture.scroll(1021, true);
    ghostty_terminal_reset(exposed);
    fixture.scroll(0, true);
    fixture.terminal.feed(bytes("\x1b[3J\x1b[2J\x1b[Hcleared"));
    fixture.scroll(0, true);
    fixture.terminal.scrollTo(0);
    fixture.publish(true);
  }
}

void benchmark(std::string_view name, std::size_t iterations) {
  const bool repeated = name == "repeat-ascii" || name == "repeat-links";
  const bool rich = name == "links" || name == "repeat-links";
  check(repeated || rich || name == "ascii" || name == "output" || name == "resize" || name == "exposed" || name == "live");
  Fixture fixture{rich};
  if (name == "exposed") {
    (void)fixture.terminal.handle();
  }

  const auto step = [&](std::size_t index) {
    if (name == "live") {
      fixture.terminal.feed(bytes("\r\nnew output"));
      fixture.publish(false, false);
      return;
    }

    if (name == "output") {
      fixture.terminal.feed(bytes("\r\nnew output"));
    } else if (name == "resize") {
      fixture.terminal.resize({.cols = static_cast<std::uint16_t>(columns - (index % 2)), .rows = rows, .cell_width_px = cell_width, .cell_height_px = cell_height});
    }

    const auto phase = static_cast<std::uint32_t>(index % (benchmark_half_cycle * 2));
    const auto offset = scroll_start + (scroll_step * (phase < benchmark_half_cycle ? phase : (benchmark_half_cycle * 2) - 1 - phase));
    fixture.scroll(offset, false);
    if (repeated) {
      fixture.scroll(offset, false);
    }
  };

  for (std::size_t index = 0; index < warmup; ++index) {
    step(index);
  }

#ifdef TELAR_SCROLL_CENSUS
  scroll_census_count = 0;
#endif

  const auto started = std::chrono::steady_clock::now();
  for (std::size_t index = 0; index < iterations; ++index) {
    step(index);
  }

  const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
#ifdef TELAR_SCROLL_CENSUS
  std::fprintf(stderr, "projected_rows=%llu\n", static_cast<unsigned long long>(scroll_census_count));
#endif

  std::printf("{\"case\":\"%.*s\",\"iterations\":%zu,\"ns\":%lld,\"observed\":%llu}\n", static_cast<int>(name.size()), name.data(), iterations, static_cast<long long>(elapsed), static_cast<unsigned long long>(fixture.observed));
}
}

int main(int argc, char **argv) {
  const std::span<char *const> arguments{argv, static_cast<std::size_t>(argc)};
  try {
    if (arguments.size() == 2 && (std::string_view{arguments[1]} == "verify" || std::string_view{arguments[1]} == "verify-observable")) {
      verify(std::string_view{arguments[1]} == "verify");
      return 0;
    }

    if (arguments.size() != 3) {
      std::fputs("Usage: probe <verify|verify-observable> | probe <ascii|links|repeat-ascii|repeat-links|output|resize|exposed|live> <iterations>\n", stderr);
      return 2;
    }

    const auto iterations = std::stoull(arguments[2]);
    if (iterations == 0) {
      return 2;
    }

    benchmark(arguments[1], iterations);
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
