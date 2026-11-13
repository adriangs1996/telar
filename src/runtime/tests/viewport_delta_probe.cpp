#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstring>
#include <cstddef>
#include <cstdint>
#include "telar_base/diagnostics/config.hpp"
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/mman.h>
#include "cell_layout.hpp"
#include <cassert>
#include <ghostty/vt.h>

import std;
import telar.base.memory;
import telar.client.protocol;
import telar.config;
import telar.gui.terminal.screen;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;
import telar.runtime.tests.check;
import telar.runtime.terminal.text_reader;

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

template <typename Sync>
void requestViewport(Sync &sync) {
  if constexpr (requires { sync.requestViewport(); }) {
    sync.requestViewport();
  } else {
    sync.requestSnapshot();
  }
}

template <typename Value>
void recordValue(const Value &value) {
  std::array<Byte, 128> storage{};
  auto remaining = std::span<Byte>{storage};
  ValueCodec<Value>::encode(value, remaining);
  record(std::span<const Byte>{storage}.first(storage.size() - remaining.size()));
}

struct Fixture {
  SystemAllocator memory;
  Terminal<SystemAllocator> terminal{memory, original_size, TerminalPurpose::separate_media};
  FrameSync<SystemAllocator> full{memory, 1};
  FrameSync<SystemAllocator> delta{memory, 1};
  std::array<Byte, decode_capacity> decode{};
  telar::gui::Screen<SystemAllocator> receiver{memory};
  std::uint64_t transmitted = 0;
  std::uint64_t transmitted_cells = 0;
  std::uint64_t snapshots = 0;
  bool defer_ack = false;
  std::uint64_t observed = 0;
  std::uint64_t full_frame_id = 0;
  std::uint64_t delta_frame_id = 0;

  explicit Fixture(bool rich) {
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
    if (emit && &sync == &full) {
      record(payload);
    }

    if (!payload.empty()) {
      const auto identity = &sync == &full ? ++full_frame_id : ++delta_frame_id;
      if (emit) {
        DecodeStorage storage{decode};
        const auto value = Codec::decode<PaneFrame>(payload, storage);
        value.validate();
        check(value.frame_id == identity);
        if (&sync == &delta) {
          check(receiver.apply(value) == telar::gui::FrameApplication::applied);
          snapshots += value.base_frame_id == 0;
          for (const auto &span : value.spans) {
            transmitted_cells += span.count;
          }
        }
      }

      observed += payload.size() + identity;
      if (&sync == &delta) {
        transmitted += payload.size();
      }
      if (&sync != &delta || !defer_ack) {
        check(sync.acknowledge(identity));
      }
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
      record(std::span<const std::uint64_t>{terminal.screen.row_revisions});
    }

    frame(delta, emit);
    if (emit) {
      check(receiver.columns() == terminal.screen.cols && receiver.rows() == terminal.screen.rows);
      std::vector<ScreenCell> canonical;
      canonical.reserve(receiver.cells().size());
      for (const auto &cell : receiver.cells()) {
        ScreenCell target{};
        target.text = cell.text;
        target.length = cell.length;
        target.width = cell.width;
        target.style = cell.style;
        canonical.push_back(target);
      }
      for (std::size_t index = 0; index < canonical.size(); ++index) {
        const auto &actual = canonical[index];
        const auto &expected = terminal.screen.cells[index];
        check(actual.length == expected.length && actual.width == expected.width && actual.style == expected.style);
        check(std::equal(actual.text.begin(), actual.text.begin() + actual.length, expected.text.begin()));
      }
      record(std::span<const ScreenCell>{canonical});
      record(receiver.rowFlags());
      FrameBody header{.pane_id = receiver.paneId(), .frame_id = 1, .cols = receiver.columns(), .rows = receiver.rows(), .cursor = receiver.cursor(), .mouse = receiver.mouse(), .input_modes = receiver.modes(), .pointer_shape = receiver.pointerShape(), .scroll = receiver.scroll()};
      std::array<Byte, 128> header_bytes{};
      auto remaining = std::span<Byte>{header_bytes};
      FrameSerializer::encodeBody(header, remaining);
      record(std::span<const Byte>{header_bytes}.first(header_bytes.size() - remaining.size()));
      check(receiver.pointerShape() == terminal.screen.pointer_shape);
      const auto status = receiver.metadataStatus();
      record(std::span{&status, std::size_t{1}});
      for (const auto &run : receiver.linkRuns()) {
        recordValue(run);
        record(bytes(receiver.linkAt(run.start)));
      }
      const std::array<Byte, 1> end{0xff};
      record(std::span<const Byte>{end});
    }
    if (restore_viewport) {
      terminal.scrollToBottom();
    }
  }

  void scroll(std::uint32_t offset, bool emit) {
    requestViewport(delta);
    receiver.setViewport(offset);
    terminal.scrollTo(offset);
    if (emit) {
      check(terminal.dirty());
    }

    publish(emit);
  }
};

void verify() {
  for (const bool rich : {false, true}) {
    Fixture fixture{rich};
    fixture.publish(true);
    fixture.defer_ack = true;
    fixture.scroll(4000, true);
    const auto first_pending = fixture.delta_frame_id;
    requestViewport(fixture.delta);
    requestViewport(fixture.delta);
    fixture.terminal.feed(bytes("\r\noutput while awaiting acknowledgment"));
    fixture.terminal.scrollTo(3994);
    fixture.terminal.refresh();
    check(fixture.delta.waitingForAck());
    check(!fixture.delta.acknowledge(first_pending - 1));
    check(!fixture.delta.acknowledge(first_pending + 1));
    check(fixture.delta.prepare(fixture.terminal.screen).empty());
    check(fixture.delta.acknowledge(first_pending));
    fixture.defer_ack = false;
    fixture.publish(true);

    fixture.defer_ack = true;
    fixture.scroll(3988, true);
    fixture.delta.requestSnapshot();
    requestViewport(fixture.delta);
    check(fixture.delta.prepare(fixture.terminal.screen).empty());
    check(fixture.delta.acknowledge(fixture.delta_frame_id));
    fixture.defer_ack = false;
    const auto snapshots_before = fixture.snapshots;
    fixture.publish(true);
    check(fixture.snapshots == snapshots_before + 1);

    fixture.defer_ack = true;
    fixture.scroll(3985, true);
    const auto obsolete = fixture.delta_frame_id;
    fixture.terminal.resize(smaller_size);
    fixture.defer_ack = false;
    fixture.scroll(3982, true);
    check(!fixture.delta.acknowledge(obsolete));
    fixture.terminal.resize(original_size);
    fixture.scroll(4000, true);

    for (const auto offset : {4000U, 3997U, 3994U, 3994U, 3997U, 4000U, 0U, 3U, 2000U, 4075U, 4096U}) {
      fixture.scroll(offset, true);
    }

    for (std::uint32_t step = 0; step < verify_half_cycle * 2; ++step) {
      fixture.scroll(scroll_start + (scroll_step * (step < verify_half_cycle ? step : (verify_half_cycle * 2) - 1 - step)), true);
    }

    requestViewport(fixture.delta);
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
    std::fprintf(stderr, "rich=%d bytes=%llu cells=%llu snapshots=%llu\n", rich,
                 static_cast<unsigned long long>(fixture.transmitted),
                 static_cast<unsigned long long>(fixture.transmitted_cells),
                 static_cast<unsigned long long>(fixture.snapshots));
  }
}

void benchmark(std::string_view name, std::size_t iterations) {
  const bool rich = name == "links";
  check(rich || name == "ascii" || name == "output" || name == "resize" || name == "exposed" || name == "live");
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
    fixture.scroll(scroll_start + (scroll_step * (phase < benchmark_half_cycle ? phase : (benchmark_half_cycle * 2) - 1 - phase)), false);
  };

  for (std::size_t index = 0; index < warmup; ++index) {
    step(index);
  }

  const auto started = std::chrono::steady_clock::now();
  for (std::size_t index = 0; index < iterations; ++index) {
    step(index);
  }

  const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
  std::printf("{\"case\":\"%.*s\",\"iterations\":%zu,\"ns\":%lld,\"observed\":%llu}\n", static_cast<int>(name.size()), name.data(), iterations, static_cast<long long>(elapsed), static_cast<unsigned long long>(fixture.transmitted));
}
}

int main(int argc, char **argv) {
  const std::span<char *const> arguments{argv, static_cast<std::size_t>(argc)};
  try {
    if (arguments.size() == 2 && std::string_view{arguments[1]} == "verify") {
      verify();
      return 0;
    }

    if (arguments.size() != 3) {
      std::fputs("Usage: probe verify | probe <ascii|links|output|resize|exposed|live> <iterations>\n", stderr);
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
