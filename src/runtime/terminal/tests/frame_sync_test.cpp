#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstring>

import std;
import telar.base.memory.allocators;
import telar.runtime.terminal.control;
import telar.testing;
import telar.runtime.terminal.text_reader;
import telar.wire.pane_io;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  std::span<const Byte> bytes(std::string_view text) {
    return {reinterpret_cast<const Byte*>(text.data()), text.size()};
  }

  std::string_view text(std::span<const Byte> value) {
    return {reinterpret_cast<const char*>(value.data()), value.size()};
  }

  // The text a frame carries for the cell at `position`, or nothing when no span covers it.
  ds::Option<std::string> changedText(const PaneFrame& frame, std::uint32_t position) {
    for (const auto& span : frame.spans) {
      if (position < span.start || position - span.start >= span.count) {
        continue;
      }

      auto reader = span.reader();

      for (std::uint32_t index = span.start; index < position; ++index) {
        check(reader.next().hasValue());
      }

      const auto cell = reader.next();

      check(cell.hasValue());
      return std::string{text(cell->text)};
    }

    return ds::none;
  }

  void testFrameSync() {
    SystemAllocator system;
    BudgetAllocator budget{system, 16 * 1024 * 1024};
    SynchronizedAllocator synchronized{budget};
    MemoryAdapter adapter{synchronized};
    ConcurrentMemory& memory = adapter;
    Screen screen{memory};

    screen.resize(80, 24);
    screen.scroll.total_rows = 24;
    FrameSync sync{memory, 7};
    ds::Array<Byte, 128 * 1024> decoded{};
    DecodeStorage storage{decoded.viewMut()};

    auto payload = sync.prepare(screen);
    auto frame = Codec::decode<PaneFrame>(payload, storage);

    check(frame.frame_id == 1);
    check(frame.base_frame_id == 0);
    check(frame.spans.size() == 1);
    check(frame.spans[0].count == 80 * 24);
    check(!sync.acknowledge(0));
    check(!sync.acknowledge(2));
    check(sync.prepare(screen).empty());

    screen.cells.atMut(17).text.atMut(0) = 'X';
    screen.row_revisions.atMut(0) = ++screen.revision;
    check(sync.prepare(screen).empty());
    check(sync.acknowledge(1));
    check(!sync.acknowledge(1));
    storage = DecodeStorage{decoded.viewMut()};
    frame = Codec::decode<PaneFrame>(sync.prepare(screen), storage);
    check(frame.frame_id == 2);
    check(frame.base_frame_id == 1);
    check(frame.spans.size() == 1);
    check(changedText(frame, 17) == "X");
    check(sync.acknowledge(2));

    const auto allocations = budget.allocations();

    ++screen.revision;
    check(sync.prepare(screen).empty());
    sync.requestSnapshot();
    storage = DecodeStorage{decoded.viewMut()};
    frame = Codec::decode<PaneFrame>(sync.prepare(screen), storage);
    check(frame.base_frame_id == 0);
    check(budget.allocations() == allocations);
    check(sync.acknowledge(frame.frame_id));
    for (const bool enabled : {true, false}) {
      screen.input_modes.paste_events = enabled;
      ++screen.revision;
      storage = DecodeStorage{decoded.viewMut()};
      frame = Codec::decode<PaneFrame>(sync.prepare(screen), storage);
      check(frame.input_modes.paste_events == enabled && frame.spans.empty());
      check(sync.acknowledge(frame.frame_id));
      check(sync.prepare(screen).empty());
    }
  }

  std::string link(std::string_view uri, std::string_view text) {
    return "\x1b]8;;" + std::string{uri} + "\x1b\\" + std::string{text} + "\x1b]8;;\x1b\\";
  }

  // Feeds `input` as a pty delivers it, a few KiB at a time, and encodes the pane's first frame.
  PaneFrame firstFrame(Terminal& terminal, FrameSync& sync, std::string_view input, std::span<Byte> decoded) {
    for (std::size_t offset = 0; offset < input.size(); offset += 4096) {
      terminal.feed(bytes(input.substr(offset, 4096)));
    }

    terminal.refresh();
    DecodeStorage storage{decoded};

    return Codec::decode<PaneFrame>(sync.prepare(terminal.screen), storage);
  }

  // The URI of the run that starts at `position`, or nothing when no run starts there.
  ds::Option<std::string_view> linkAt(const TextMetadata& metadata, std::uint32_t position) {
    const auto run = std::ranges::find(metadata.runs, position, &MetadataRun::start);
    if (run == metadata.runs.end()) {
      return ds::none;
    }

    return text(metadata.link(run->link_index));
  }

  constexpr std::string_view first_uri = "https://first.example/";

  // A link the pane prints reaches the client as a run over its cells with its URI. More
  // links, longer URIs or more runs than a frame carries mark the metadata partial, and the
  // frame still encodes with the first link in it.
  void testHyperlinkMetadataBounded() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    std::vector<Byte> decoded(8 * 1024 * 1024);

    {
      Terminal terminal{memory, TerminalSize{80, 24, 0, 0}};
      FrameSync sync{memory, 7};
      const auto frame = firstFrame(terminal, sync, "ab" + link(first_uri, "link") + "cd", decoded);

      check(frame.text_metadata && frame.text_metadata->status == MetadataStatus::complete);
      check(frame.text_metadata->runs.size() == 1 && frame.text_metadata->runs[0].len == 4);
      check(linkAt(*frame.text_metadata, 2) == first_uri);
    }

    std::string many_links;
    std::string many_uri_bytes;
    std::string many_runs;

    for (std::size_t index = 0; index < 1000; ++index) {
      many_links.append(link("https://many.example/" + std::to_string(index), "x"));
    }

    for (std::size_t index = 0; index < 200; ++index) {
      many_uri_bytes.append(link("https://long.example/" + std::to_string(index) + "/" + std::string(1900, 'u'), "x"));
    }

    // Two links named by id, alternating cell by cell: each cell starts a run of its own.
    for (std::size_t index = 0; index < 6000; ++index) {
      many_runs.append(index % 2 == 0 ? "\x1b]8;id=even;https://even.example/\x1b\\x" : "\x1b]8;id=odd;https://odd.example/\x1b\\x");
    }

    for (const auto& flood : {many_links, many_uri_bytes, many_runs}) {
      Terminal terminal{memory, TerminalSize{200, 60, 0, 0}};
      FrameSync sync{memory, 7};
      const auto frame = firstFrame(terminal, sync, link(first_uri, "x") + flood, decoded);

      check(frame.text_metadata && frame.text_metadata->status == MetadataStatus::partial);
      check(linkAt(*frame.text_metadata, 0) == first_uri);
    }
  }

  // A pane that prints a screenful of links, each cell its own, keeps working: the terminal
  // takes all of its output and the frame encodes with the first link in it.
  void testHyperlinkFloodKeepsPane() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    std::vector<Byte> decoded(8 * 1024 * 1024);
    Terminal terminal{memory, TerminalSize{80, 24, 0, 0}};
    FrameSync sync{memory, 7};
    std::string screenful = link(first_uri, "x");

    for (std::size_t index = 1; index < 80 * 23; ++index) {
      screenful.append(link("https://cell.example/" + std::to_string(index), "x"));
    }

    const auto frame = firstFrame(terminal, sync, screenful, decoded);

    check(frame.text_metadata && linkAt(*frame.text_metadata, 0) == first_uri);
  }

  const telar::testing::Case case_frame_sync{"frame_sync.frame_sync", testFrameSync};
  const telar::testing::Case case_hyperlink_metadata_bounded{"frame_sync.hyperlink_metadata_bounded", testHyperlinkMetadataBounded};
  const telar::testing::Case case_hyperlink_flood_keeps_pane{"frame_sync.hyperlink_flood_keeps_pane", testHyperlinkFloodKeepsPane};

}
