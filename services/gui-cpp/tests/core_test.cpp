#include "application/pane_layout.hpp"
#include "core/cell_rectangle.hpp"
#include "core/configuration.hpp"
#include "core/geometry.hpp"
#include "core/memory.hpp"
#include "core/metrics.hpp"
#include "input/history_text.hpp"
#include "input/mouse_encoder.hpp"
#include "telar_client/codecs/telar_cells.hpp"
#include "telar_client/codecs/telar_codec.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "terminal/copy_range.hpp"
#include "terminal/screen.hpp"
#include "transport/frame_stream.hpp"
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <exception>
#include <iostream>
#include <limits>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>

namespace {

void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

bool acceptsHistory(std::string_view text, bool bracketed_paste) {
  try {
    telar::gui::HistoryText::validate(text, bracketed_paste);

    return true;
  } catch (const telar::EncodingError &) {
    return false;
  }
}

void historyTextSafety() {
  constexpr unsigned first_printable = 0x20;
  constexpr unsigned delete_control = 0x7f;
  for (unsigned code = 0; code <= delete_control; ++code) {
    const auto character = static_cast<char>(code);
    const std::string_view text{&character, 1};
    const bool printable = code >= first_printable && code != delete_control;
    require(acceptsHistory(text, false) == printable, "unframed history must reject every ASCII control");
    require(acceptsHistory(text, true) == (printable || character == '\n' || character == '\t'), "bracketed history may additionally contain newlines and tabs");
  }

  constexpr unsigned first_extended_control = 0x80;
  constexpr unsigned last_extended_control = 0x9f;
  constexpr unsigned extended_control_lead = 0xc2;
  for (unsigned code = first_extended_control; code <= last_extended_control; ++code) {
    const std::array text{static_cast<char>(extended_control_lead), static_cast<char>(code)};
    require(!acceptsHistory({text.data(), text.size()}, true), "UTF-8 C1 controls must not bypass history validation");
  }

  constexpr auto malformed = std::to_array<std::string_view>({"\x80", "\xc0\xaf", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xc2"});
  for (const auto text : malformed) {
    require(!acceptsHistory(text, true), "malformed UTF-8 must be rejected before history input");
  }

  require(acceptsHistory("printf 'café 🌱'", false), "printable Unicode must retain its exact UTF-8 bytes");
  require(acceptsHistory("printf '\xc2\xa0'", false), "nonbreaking space must not be confused with C1 controls");
  require(!acceptsHistory({}, true), "empty history commands must be rejected");
  std::string bounded(telar::gui::HistoryText::maximum_bytes, 'a');
  require(acceptsHistory(bounded, true), "maximum-size captured commands must be accepted");
  bounded.push_back('a');
  require(!acceptsHistory(bounded, true), "oversized commands must be rejected without truncation");
}

void borrowedByteViews() {
  using namespace telar;

  constexpr std::string_view raw{"a\0\xff", 3};
  constexpr Byte high_byte = 0xff;
  const auto bytes = byteView(raw);
  require(bytes.size() == raw.size() && bytes[0] == 'a' && bytes[1] == 0 && bytes[2] == high_byte, "shared byte views must preserve embedded zero and high-bit bytes");
  const auto text = textView(bytes);
  require(text == raw && text.data() == raw.data(), "shared character views must borrow the existing representation without copying");
}

void screenFrames() {
  using namespace telar;
  using namespace telar::gui;

  SystemAllocator upstream;
  constexpr std::size_t allocation_budget = std::size_t{1} * 1024 * 1024;
  BudgetAllocator memory{upstream, allocation_budget};

  {
    Screen screen{memory};
    const std::array<Byte, 1> text{'x'};
    std::array<Cell, 4> cells;
    for (auto &cell : cells) {
      cell.text = text;
    }

    constexpr std::size_t cell_buffer_bytes = 256;
    std::array<Byte, cell_buffer_bytes> encoded{};
    const auto run = CellRunCodec::encode(cells, encoded);
    const std::array<FrameSpan, 1> spans{{{.start = 0, .count = 4, .cells = run}}};
    const std::array<Byte, 2> flags{};
    PaneFrame frame;
    frame.pane_id = 1;
    frame.frame_id = 1;
    frame.cols = 2;
    frame.rows = 2;
    frame.scroll.total_rows = 2;
    frame.text_metadata = TextMetadata{.row_flags = flags};
    frame.spans = spans;

    require(screen.apply(frame) == FrameApplication::applied, "snapshot must apply");
    require(screen.row(0)[0].utf8() == "x", "screen must own text");
    require(screen.apply(frame) == FrameApplication::stale, "duplicate frame must be ignored");

    const auto second_row_revision = screen.rowRevision(1);
    frame.frame_id = 2;
    frame.base_frame_id = 1;
    frame.text_metadata.reset();
    const auto delta_run = CellRunCodec::encode(std::span{cells}.first(1), encoded);
    const std::array<FrameSpan, 1> delta_spans{{{.start = 0, .count = 1, .cells = delta_run}}};
    frame.spans = delta_spans;
    require(screen.apply(frame) == FrameApplication::applied, "delta must apply");
    require(screen.rowRevision(1) == second_row_revision, "unchanged row must retain its revision");

    frame.frame_id = 4;
    require(screen.apply(frame) == FrameApplication::needs_snapshot, "missing delta base must request a snapshot");
    require(screen.frameId() == 2, "rejected frame must not modify screen");

    frame.base_frame_id = 2;
    const std::array<Byte, 1> malformed{0xff};
    const std::array<FrameSpan, 1> bad_spans{{{.start = 0, .count = 1, .cells = malformed}}};
    frame.spans = bad_spans;
    bool rejected = false;
    try {
      screen.apply(frame);
    } catch (const EncodingError &) {
      rejected = true;
    }

    require(rejected && screen.frameId() == 2, "invalid cells must be rejected before mutation");
  }

  require(memory.liveBytes() == 0, "screen must release injected allocations");
}

void splitLayout() {
  using namespace telar;
  using namespace telar::gui;

  PaneLayout layout;
  require(layout.add(1, ClientLayoutAxis::horizontal, 0), "first pane");
  require(layout.add(2, ClientLayoutAxis::horizontal, 1), "horizontal split");
  require(layout.add(3, ClientLayoutAxis::vertical, 2), "vertical split");
  constexpr CellRectangle viewport{.width = 100, .height = 100};
  const auto placements = layout.arrange(viewport, {.gap = 2});
  require(placements.size() == 3, "three leaves");
  constexpr std::uint16_t expected_pane_width = 49;
  constexpr std::uint16_t expected_nested_top = 51;
  require(placements[0].bounds.width == expected_pane_width, "split must account for separator");
  require(placements[2].bounds.y == expected_nested_top, "nested vertical split");
  require(layout.dividers().size() == 2, "every split must expose an independent resize handle");
  require(layout.resize(3, PaneDirection::up, viewport, {.gap = 2}), "nested pane must resize its nearest matching edge");
  require(std::get<ClientLayoutSplit>(layout.nodes()[2]).ratio == PaneLayout::ratio_half - PaneLayout::resize_step, "resize must move the requested edge by five percent");
  require(layout.resize(1, PaneDirection::left, viewport, {.gap = 2}), "outside edge must fall back to its nearest opposite divider");
  require(std::get<ClientLayoutSplit>(layout.nodes()[0]).ratio == PaneLayout::ratio_half - PaneLayout::resize_step, "fallback must preserve the requested movement direction");
  require(layout.setSplitRatio({.node_index = 0, .ratio = 0}) && std::get<ClientLayoutSplit>(layout.nodes()[0]).ratio == PaneLayout::ratio_minimum, "pointer resizing must clamp ratios");
  require(!layout.setSplitRatio({.node_index = 1, .ratio = PaneLayout::ratio_half}), "leaf nodes cannot accept split ratios");
  require(layout.remove(2), "remove nested leaf");
  require(layout.nodes().size() == 3 && layout.contains(1) && layout.contains(3), "remove must collapse its parent");
  require(layout.remove(1) && layout.firstPane() == 3, "remove first subtree");

  const std::array<ClientLayoutNode, 2> incomplete{
      ClientLayoutSplit{.axis = ClientLayoutAxis::horizontal, .ratio = 5000},
      ClientLayoutPane{7},
  };
  bool rejected = false;
  try {
    layout.restore(incomplete);
  } catch (const EncodingError &) {
    rejected = true;
  }

  require(rejected && layout.firstPane() == 3, "invalid restore must preserve layout");
}

void requireLayoutCoverage(const telar::gui::PaneLayout &layout, std::span<const telar::gui::PaneLayout::Placement> placements, telar::gui::CellRectangle viewport) {
  std::uint64_t area = 0;
  for (const auto &placement : placements) {
    const auto &bounds = placement.bounds;
    require(bounds.x >= viewport.x && bounds.y >= viewport.y && bounds.right() <= viewport.right() && bounds.bottom() <= viewport.bottom(), "every pane must remain inside its viewport");
    require(bounds.width >= 0 && bounds.height >= 0, "collapsed panes cannot have negative extents");
    area += static_cast<std::uint64_t>(bounds.width) * bounds.height;
    for (const auto &other : placements) {
      if (other.pane_id != placement.pane_id) {
        require(bounds.intersect(other.bounds).empty(), "pane interiors cannot overlap");
      }
    }
  }

  for (const auto &divider : layout.dividers()) {
    area += static_cast<std::uint64_t>(divider.bounds.width) * divider.bounds.height;
  }

  require(area == static_cast<std::uint64_t>(viewport.width) * viewport.height, "panes and dividers must cover the viewport exactly");
}

void layoutCapacity() {
  using namespace telar;
  using namespace telar::gui;

  constexpr CellRectangle viewport{.width = 1024, .height = 768};
  constexpr std::uint8_t gap = 2;
  constexpr std::uint64_t first_pane = 1;

  for (const bool deepest_first : {false, true}) {
    PaneLayout layout;
    require(layout.add(first_pane, ClientLayoutAxis::horizontal, 0), "create capacity fixture");
    for (std::size_t index = 1; index < PaneLayout::maximum_panes; ++index) {
      const auto axis = index % 2 == 0 ? ClientLayoutAxis::horizontal : ClientLayoutAxis::vertical;
      const auto beside = deepest_first ? first_pane : index;
      require(layout.add(index + first_pane, axis, beside), "every pane within the capacity must be admitted");
    }

    require(!layout.add(PaneLayout::maximum_panes + first_pane, ClientLayoutAxis::horizontal, first_pane), "capacity must reject an additional pane");
    const auto placements = layout.arrange(viewport, {.gap = gap});
    require(placements.size() == PaneLayout::maximum_panes, "deep layouts must retain every leaf");
    require(layout.dividers().size() == PaneLayout::maximum_panes - 1, "deep layouts must retain every divider");
    requireLayoutCoverage(layout, placements, viewport);
    const auto fullscreen = layout.arrange(viewport, {.gap = gap}, first_pane);
    require(fullscreen.size() == 1 && fullscreen.front().bounds == viewport && layout.dividers().empty(), "fullscreen must discard split geometry");
  }
}

void fragmentedTransport() {
  using namespace telar;
  using namespace telar::gui;

  SystemAllocator memory;
  const auto payload = Codec::encode(PaneExited{.pane_id = 1, .kind = ExitKind::exited, .value = 0});
  std::array<Byte, frame_prefix_size + payload.size()> bytes{};
  std::span<Byte> output{bytes};
  u32::encode(payload.size(), output);
  std::ranges::copy(payload, output.begin());

  for (std::size_t split = 0; split <= bytes.size(); ++split) {
    FrameStream stream{memory};
    std::size_t received = 0;
    const auto consume = [&](std::span<const Byte> frame) {
      require(Codec::decode<PaneExited>(frame).pane_id == 1, "fragmented payload");
      ++received;
    };

    stream.feed(std::span{bytes}.first(split), consume);
    stream.feed(std::span{bytes}.subspan(split), consume);
    require(received == 1, "every fragmentation must emit exactly one frame");
  }

  FrameStream stream{memory};
  const std::array<Byte, frame_prefix_size> invalid{};
  bool rejected = false;
  const auto ignore_payload = [](std::span<const Byte>) {
  };

  try {
    stream.feed(invalid, ignore_payload);
  } catch (const EncodingError &) {
    rejected = true;
  }

  require(rejected, "zero-length frames must fail");
  stream.reset();
  std::size_t received = 0;
  const auto count_frame = [&](std::span<const Byte> frame) {
    require(Codec::decode<PaneExited>(frame).pane_id == 1, "reset frames must decode with a fresh prefix");
    ++received;
  };
  stream.feed(bytes, count_frame);
  require(received == 1, "a reset must discard the failed connection's partial frame");
}

void terminalConsumerStopsBeforeTheNextFrame() {
  using namespace telar;
  using namespace telar::gui;

  SystemAllocator upstream;
  constexpr std::size_t payload_bytes = 1;
  BudgetAllocator memory{upstream, payload_bytes};
  {
    FrameStream stream{memory};
    std::array<Byte, (2 * frame_prefix_size) + payload_bytes> bytes{};
    std::span<Byte> output{bytes};
    u32::encode(payload_bytes, output);
    output.front() = 'T';
    std::size_t received = 0;
    const auto terminal = [&](std::span<const Byte> payload) {
      require(payload.size() == payload_bytes && payload.front() == 'T', "The terminal frame must arrive intact");
      ++received;

      return false;
    };
    try {
      stream.feed(bytes, terminal);
    } catch (const EncodingError &) {
      require(false, "A terminal consumer must stop before decoding the next frame prefix");
    }

    require(received == 1 && memory.liveBytes() == payload_bytes, "A terminal consumer must deliver only its final frame");
    stream.reset();
    stream.feed(std::span{bytes}.first(frame_prefix_size + payload_bytes), terminal);
    require(received == 2, "A new session must parse normally after resetting a finished stream");
  }

  require(memory.liveBytes() == 0, "Finished stream storage must retain its allocator ownership");
}

void mouseEncoding() {
  telar::gui::MouseEncoder encoder;
  constexpr unsigned column = 12;
  constexpr unsigned row = 34;
  constexpr unsigned first_unrepresentable_coordinate = 224;
  require(encoder.encode(0, column, row, false, true) == "\x1b[<0;12;34M", "SGR mouse press");
  require(encoder.encode(0, column, row, true, true) == "\x1b[<0;12;34m", "SGR mouse release");
  require(encoder.encode(0, first_unrepresentable_coordinate, 1, false, false).empty(), "legacy mouse coordinates must remain within the protocol bound");
}

void copyRanges() {
  using namespace telar;
  using namespace telar::gui;

  constexpr std::uint64_t pane_id = 7;
  const auto range = CopyRangeParser::parse(pane_id, "0,10:79,12");
  constexpr std::uint32_t start_row = 10;
  constexpr std::uint16_t end_column = 79;
  constexpr std::uint32_t end_row = 12;
  require(range.pane_id == pane_id && range.start_x == 0 && range.start_y == start_row && range.end_x == end_column && range.end_y == end_row && !range.linewise, "copy range must preserve inclusive history coordinates");

  const auto maximum = CopyRangeParser::parse(pane_id, "65__535,4_294_967_295:000,0");
  require(maximum.start_x == std::numeric_limits<std::uint16_t>::max() && maximum.start_y == std::numeric_limits<std::uint32_t>::max() && maximum.end_x == 0, "copy coordinates must accept the original parser's decimal separators and full capacities");

  for (const auto *const text : {"", "0,1", "0,1:2", "0,1:2,3:4", "0,1,2:3,4", ",1:2,3", "0,:2,3", "0,1:,3", "0,1:2,", "65536,1:2,3", "0,4294967296:2,3", "_0,1:2,3", "0_,1:2,3", "+0,1:2,3", "-0,1:2,3", " 0,1:2,3", "0,1:2,3 "}) {
    bool rejected = false;
    try {
      CopyRangeParser::parse(pane_id, text);
    } catch (const EncodingError &) {
      rejected = true;
    }

    require(rejected, "malformed copy ranges must be rejected before sending a request");
  }
}

void windowGeometry() {
  using namespace telar::gui;

  Configuration configuration;
  const Viewport viewport{.width = 1200, .height = 800, .scale = 1};
  const CellMetrics cells;
  const auto initial = WindowGeometry::measure(configuration, viewport, cells);
  const auto original_chrome = ChromeMetrics::resolve(configuration, viewport, cells);
  constexpr float increased_chrome_scale = 1.5F;
  configuration.chrome_scale = increased_chrome_scale;
  const auto scaled = WindowGeometry::measure(configuration, viewport, cells);
  const auto scaled_chrome = ChromeMetrics::resolve(configuration, viewport, cells);
  require(initial.terminal == scaled.terminal && original_chrome.top_bar == scaled_chrome.top_bar && original_chrome.title < scaled_chrome.title, "chrome scale must change text without changing terminal geometry or band heights");

  constexpr float horizontal_padding = 10;
  constexpr float vertical_padding = 12;
  configuration.padding_x = horizontal_padding;
  configuration.padding_y = vertical_padding;
  const auto padded = WindowGeometry::measure(configuration, viewport, cells);
  require(padded.terminal.y == padded.navigation.height + vertical_padding && padded.terminal.right() == static_cast<float>(viewport.width) - horizontal_padding, "window padding must apply once in logical coordinates");
  const auto narrow = WindowGeometry::measure(configuration, {.width = 300, .height = 200, .scale = 1}, cells);
  require(narrow.rail && narrow.sidebar.width == WindowGeometry::sidebar_rail && narrow.terminal.width > 0, "narrow windows must retain a terminal and collapse the sidebar to its rail");
}

}

int main() {
  try {
    borrowedByteViews();
    historyTextSafety();
    screenFrames();
    splitLayout();
    layoutCapacity();
    fragmentedTransport();
    terminalConsumerStopsBeforeTheNextFrame();
    mouseEncoding();
    copyRanges();
    windowGeometry();
    std::puts("gui-core: passed");
  } catch (const std::exception &error) {
    std::cerr << "gui-core: " << error.what() << '\n';

    return 1;
  }
}
