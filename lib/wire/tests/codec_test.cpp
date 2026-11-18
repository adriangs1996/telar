#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstring>

import std;
import telar.testing;
import telar.vocabulary;
import telar.wire.vocabulary;
import telar.wire.agents;
import telar.wire.clients;
import telar.wire.editor;
import telar.wire.execution;
import telar.wire.history;
import telar.wire.graphics;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.base.ds;
import telar.base.memory.allocators;

namespace {

  using telar::testing::check;

  using namespace telar;

  using Bytes = std::vector<Byte>;

  template <typename Message>
  Bytes encoded(const Message& message) {
    Bytes bytes(Codec::encodedSize(message));

    static_cast<void>(Codec::encode(message, std::span<Byte>{bytes}));
    return bytes;
  }

  // The bytes a peer that skips validation would send: the tag and the body, unchecked.
  template <typename Message>
  Bytes unchecked(const Message& message) {
    Bytes bytes(u8::width + MessageSchema<Message>::encodedSize(message));
    std::span<Byte> output{bytes};

    u8::encode(static_cast<Byte>(MessageSchema<Message>::tag), output);
    MessageSchema<Message>::encodeBody(message, output);
    check(output.empty());
    return bytes;
  }

  // Storage for the lists a decoded message holds, aligned for any element.
  struct Storage {
    explicit Storage(std::size_t bytes)
        : words((bytes + sizeof(std::max_align_t) - 1) / sizeof(std::max_align_t)),
          size(bytes) {}

    DecodeStorage view() {
      return {.remaining = {reinterpret_cast<Byte*>(words.data()), size}};
    }

    std::vector<std::max_align_t> words;
    std::size_t size;
  };

  // Decodes `bytes` from an exactly sized heap copy, so a read past them is an overflow the
  // sanitize preset reports, and returns the message or nullopt when the codec refused it.
  template <typename Message, typename Inspect>
  bool decodes(std::span<const Byte> bytes, Storage& storage, Inspect&& inspect) {
    const auto copy = std::make_unique<Byte[]>(bytes.size());

    if (!bytes.empty()) {
      std::memcpy(copy.get(), bytes.data(), bytes.size());
    }

    auto lists = storage.view();

    try {
      const auto message = Codec::decode<Message>(std::span<const Byte>{copy.get(), bytes.size()}, lists);

      inspect(message);
    } catch (const EncodingError&) {
      return false;
    }

    return true;
  }

  template <typename Message>
  bool refused(std::span<const Byte> bytes, std::size_t storage_bytes = 64 * 1024) {
    Storage storage{storage_bytes};

    return !decodes<Message>(bytes, storage, [](const Message&) {});
  }

  template <typename Message>
  bool encodeRefused(const Message& message) {
    try {
      static_cast<void>(encoded(message));
    } catch (const EncodingError&) {
      return true;
    }

    return false;
  }

  // The one byte where two encodings of the same size differ.
  std::size_t differingByte(const Bytes& left, const Bytes& right) {
    check(left.size() == right.size());
    ds::Option<std::size_t> found;

    for (std::size_t index = 0; index < left.size(); ++index) {
      if (left[index] != right[index]) {
        check(!found, "the encodings differ in more than one byte");
        found = index;
      }
    }

    check(found.hasValue());
    return *found;
  }

  std::size_t find(const Bytes& bytes, std::span<const Byte> needle) {
    const auto found = std::ranges::search(bytes, needle);

    check(!found.empty() && std::ranges::search(found.end(), bytes.end(), needle.begin(), needle.end()).empty(), "the sequence occurs exactly once");
    return static_cast<std::size_t>(found.begin() - bytes.begin());
  }

  // `bytes` with its one occurrence of `from` replaced by `to`.
  Bytes patched(Bytes bytes, std::span<const Byte> from, std::span<const Byte> to) {
    const auto at = find(bytes, from);

    bytes.erase(bytes.begin() + static_cast<std::ptrdiff_t>(at), bytes.begin() + static_cast<std::ptrdiff_t>(at + from.size()));
    bytes.insert(bytes.begin() + static_cast<std::ptrdiff_t>(at), to.begin(), to.end());
    return bytes;
  }

  Bytes text(std::string_view value) {
    return {value.begin(), value.end()};
  }

  Bytes concatenated(std::initializer_list<Bytes> parts) {
    Bytes bytes;

    for (const auto& part : parts) {
      bytes.insert(bytes.end(), part.begin(), part.end());
    }

    return bytes;
  }

  // A frame or a peer can be cut anywhere: every proper prefix of a message with text, bytes,
  // lists and an optional value is refused, and never read past.
  void testTruncatedPayloadIsRejectedAtEveryCut() {
    const ds::Array<std::string_view, 3> arguments{"sh", "-c", "echo hi"};
    const ds::Array<EnvironmentEntry, 2> environment{{{"A", "1"}, {"PATH", "/bin"}}};
    const OpenPane message{
        .request_id = 7,
        .target = {},
        .size = {.cols = 80, .rows = 24, .cell_width_px = 8, .cell_height_px = 16},
        .launch = Launch{.cwd = "/tmp", .cwd_source = 3, .arguments = arguments, .environment_mode = EnvironmentMode::replace, .environment = environment},
    };

    const auto bytes = encoded(message);
    Storage storage{4096};

    check(decodes<OpenPane>(bytes, storage, [&](const OpenPane& decoded) {
      check(decoded.launch && decoded.launch->cwd == "/tmp" && decoded.launch->arguments.size() == 3 && decoded.launch->arguments[2] == "echo hi");
      check(decoded.launch->environment.size() == 2 && decoded.launch->environment[1].value == "/bin");
    }));

    for (std::size_t length = 0; length < bytes.size(); ++length) {
      check(refused<OpenPane>(std::span{bytes}.first(length)), "a truncated message was accepted");
    }
  }

  // Decoded lists live in storage the caller sized: a list that does not fit is refused rather
  // than written past it.
  void testDecodeStorageExhaustionIsRefused() {
    const ds::Array<LimitListEntry, 3> entries{{
        {.reach = {.name = "a.one", .noun = "things", .value = 1}, .hits = 1},
        {.reach = {.name = "a.two", .noun = "things", .value = 2}, .hits = 2},
        {.reach = {.name = "a.three", .noun = "things", .value = 3}, .hits = 3},
    }};

    const auto bytes = encoded(LimitList{.request_id = 1, .entries = entries});

    check(refused<LimitList>(bytes, (entries.size() * sizeof(LimitListEntry)) - 1));
    check(refused<LimitList>(bytes, 0));

    Storage storage{entries.size() * sizeof(LimitListEntry)};

    check(decodes<LimitList>(bytes, storage, [](const LimitList& decoded) {
      check(decoded.entries.size() == 3 && decoded.entries[2].reach.name == "a.three" && decoded.entries[2].hits == 3);
    }));
  }

  AgentSnapshotEntry agent(AgentStatus status) {
    return {
        .pane_id = 1,
        .pane_generation = 1,
        .location = {.workspace = {.id = 1}, .tab_id = 1},
        .pane_index = 1,
        .status = status,
        .sequence = 1,
    };
  }

  // An enum byte past its last value is refused: the CLI indexes its names by the status.
  void testEnumBytesBeyondRangeAreRejected() {
    const ds::Array done{agent(AgentStatus::done)};
    const ds::Array failed{agent(AgentStatus::failed)};
    const auto last = encoded(AgentSnapshot{.revision = 1, .entries = done});
    const auto status = differingByte(last, encoded(AgentSnapshot{.revision = 1, .entries = failed}));
    auto beyond = last;

    beyond[status] = static_cast<Byte>(static_cast<Byte>(AgentStatus::done) + 1);
    check(!refused<AgentSnapshot>(last));
    check(refused<AgentSnapshot>(beyond));

    const auto wildcard = encoded(ProxyStatus{.active = true, .scope = ProxyScope::wildcard});
    const auto scope = differingByte(wildcard, encoded(ProxyStatus{.active = true, .scope = ProxyScope::exact}));
    auto unknown = wildcard;

    unknown[scope] = static_cast<Byte>(static_cast<Byte>(ProxyScope::wildcard) + 1);
    check(!refused<ProxyStatus>(wildcard));
    check(refused<ProxyStatus>(unknown));
  }

  Notification notification(std::string_view link) {
    Notification value{};

    value.title = "Build";
    value.link = link;
    return value;
  }

  // The GUI opens a notification's link as it is and shows its host, so a link whose host could
  // be spoofed, through a backslash, user information or a malformed name, is refused.
  void testNotificationLinkRejectsUnsafeUrls() {
    for (const std::string_view link : {"http://example.com/", "https://example.com/a\\b", "https://example.com/a b", "https://good.com\\@evil.com", "https://a b", "https://user@host/", "https://.x", "https://-x", "https://x.", "https://", "https://ex\x01"
                                                                                                                                                                                                                                                "ample.com"}) {
      check(encodeRefused(notification(link)), link);
    }

    constexpr std::string_view safe = "https://example.com/p?q";
    const auto bytes = encoded(notification(safe));

    check(notificationLinkHost(safe) == "example.com");
    check(!refused<Notification>(bytes));
    check(refused<Notification>(patched(bytes, text("example.com/p"), text("example.com\\p"))));
    check(refused<Notification>(patched(bytes, text("example.com/p"), text("example@com/p"))));
  }

  // A snapshot of a 4x2 grid with two hyperlinks over three runs.
  struct FrameFixture {
    FrameFixture() {
      ds::Array<Cell, 8> grid;
      const ds::Array<Byte, 1> letter{'a'};

      for (auto& cell : grid.viewMut()) {
        cell.text = letter;
      }

      cells.resize(CellRunCodec::encodedSize(grid));
      static_cast<void>(CellRunCodec::encode(grid, std::span<Byte>{cells}));
      half.resize(CellRunCodec::encodedSize(std::span{grid}.first(4)));
      static_cast<void>(CellRunCodec::encode(std::span{grid}.first(4), std::span<Byte>{half}));
      spans.atMut(0) = {.start = 0, .count = 8, .cells = cells};
    }

    TextMetadata metadata() const {
      return {.status = MetadataStatus::complete, .row_flags = row_flags, .links = links, .runs = runs, .uris = uris};
    }

    PaneFrame snapshot() const {
      PaneFrame frame{};

      frame.pane_id = 1;
      frame.frame_id = 1;
      frame.cols = 4;
      frame.rows = 2;
      frame.scroll = {.total_rows = 2, .offset = 0};
      frame.text_metadata = metadata();
      frame.spans = spans;
      return frame;
    }

    Bytes cells;
    Bytes half;
    ds::Array<FrameSpan, 1> spans;
    ds::Array<Byte, 2> row_flags{static_cast<Byte>(RowFlag::hyperlinks), static_cast<Byte>(RowFlag::hyperlinks)};
    ds::Array<MetadataLink, 2> links{{{.offset = 0, .len = 5}, {.offset = 5, .len = 7}}};
    ds::Array<MetadataRun, 3> runs{{{.start = 0, .len = 2, .link_index = 0}, {.start = 2, .len = 1, .link_index = 1}, {.start = 4, .len = 3, .link_index = 1}}};
    ds::Array<Byte, 12> uris{'h', 't', 't', 'p', 's', 'e', 'x', 'a', 'm', 'p', 'l', 'e'};
  };

  // The runtime encodes a frame's hyperlinks and the GUI decodes them: links, runs, URIs and row
  // flags come back as they were sent.
  void testFrameMetadataHyperlinksRoundTrip() {
    const FrameFixture fixture;
    Storage storage{64 * 1024};

    check(decodes<PaneFrame>(encoded(fixture.snapshot()), storage, [&](const PaneFrame& frame) {
      check(frame.text_metadata.hasValue());
      const auto& metadata = *frame.text_metadata;

      check(std::ranges::equal(metadata.row_flags, fixture.row_flags) && std::ranges::equal(metadata.uris, fixture.uris));
      check(metadata.links.size() == fixture.links.size() && metadata.runs.size() == fixture.runs.size());
      for (std::size_t index = 0; index < fixture.links.size(); ++index) {
        check(metadata.links[index].offset == fixture.links[index].offset && metadata.links[index].len == fixture.links[index].len);
      }

      for (std::size_t index = 0; index < fixture.runs.size(); ++index) {
        check(metadata.runs[index].start == fixture.runs[index].start && metadata.runs[index].len == fixture.runs[index].len && metadata.runs[index].link_index == fixture.runs[index].link_index);
      }

      check(std::ranges::equal(metadata.link(1), std::span{fixture.uris}.subspan(5)));
    }));
  }

  // The GUI slices a link's URI bytes without checks of its own, so a frame whose links or runs
  // point outside what it carries is refused when it is decoded.
  void testFrameMetadataRejectsOutOfBoundsLinks() {
    const FrameFixture fixture;
    const auto refusedWith = [&](auto&& change) {
      auto metadata = fixture.metadata();
      auto links = fixture.links;
      auto runs = fixture.runs;
      auto row_flags = fixture.row_flags;
      ds::Array<Byte, 13> longer_uris{};

      std::ranges::copy(fixture.uris, longer_uris.viewMut().begin());
      metadata.links = links;
      metadata.runs = runs;
      metadata.row_flags = row_flags;
      change(metadata, links, runs, row_flags, longer_uris);
      auto frame = fixture.snapshot();

      frame.text_metadata = metadata;
      return refused<PaneFrame>(unchecked(frame));
    };

    check(!refused<PaneFrame>(unchecked(fixture.snapshot())));
    check(refusedWith([](TextMetadata&, auto& links, auto&, auto&, auto&) {
      links.atMut(0) = {.offset = 1, .len = 4};
    }));

    check(refusedWith([](TextMetadata&, auto& links, auto&, auto&, auto&) {
      links.atMut(1) = {.offset = 5, .len = 8};
    }));

    // Lengths that add up to the URI bytes, but the second link starts past the first's end, so
    // its bytes run off the end of the URIs.
    check(refusedWith([](TextMetadata&, auto& links, auto&, auto&, auto&) {
      links.atMut(1) = {.offset = 6, .len = 7};
    }));

    check(refusedWith([](TextMetadata& metadata, auto&, auto&, auto&, auto& longer_uris) {
      metadata.uris = longer_uris;
    }));

    check(refusedWith([](TextMetadata&, auto&, auto& runs, auto&, auto&) {
      runs.atMut(2).link_index = 2;
    }));

    check(refusedWith([](TextMetadata&, auto&, auto& runs, auto&, auto&) {
      runs.atMut(2) = {.start = 3, .len = 2, .link_index = 1};
    }));

    check(refusedWith([](TextMetadata&, auto&, auto&, auto& row_flags, auto&) {
      row_flags.atMut(1) = 0x40;
    }));
  }

  // Clients copy a frame's spans into their grid at the offsets it names, so a header that
  // places them outside the grid, or a snapshot that does not cover it, is refused.
  void testFrameHeaderRejectsSpansOutsideGrid() {
    const FrameFixture fixture;
    const auto snapshot = fixture.snapshot();
    const auto delta = [&](std::span<const FrameSpan> spans) {
      auto frame = snapshot;

      frame.frame_id = 2;
      frame.base_frame_id = 1;
      frame.text_metadata.reset();
      frame.spans = spans;
      return frame;
    };

    const ds::Array<FrameSpan, 1> first_row{{{.start = 0, .count = 4, .cells = fixture.half}}};
    const ds::Array<FrameSpan, 2> overlapping{{{.start = 0, .count = 4, .cells = fixture.half}, {.start = 2, .count = 4, .cells = fixture.half}}};
    const ds::Array<FrameSpan, 1> past_grid{{{.start = 6, .count = 4, .cells = fixture.half}}};

    check(!refused<PaneFrame>(unchecked(snapshot)));
    check(!refused<PaneFrame>(unchecked(delta(first_row))));

    auto same_base = delta(first_row);
    auto cursor = snapshot;
    auto scrolled = snapshot;
    auto bare = snapshot;
    auto partial = snapshot;

    same_base.base_frame_id = same_base.frame_id;
    cursor.cursor = {.visible = true, .x = 4, .y = 0};
    scrolled.scroll.offset = 1;
    bare.text_metadata.reset();
    partial.spans = first_row;
    for (const auto& frame : {same_base, cursor, scrolled, delta(overlapping), delta(past_grid), bare, partial}) {
      check(refused<PaneFrame>(unchecked(frame)));
    }
  }

  // A cell run is parsed byte by byte by every client: a first cell without a style, text past
  // the run, bytes after its last cell or a width other than 0 to 2 are refused.
  void testCellReaderRejectsMalformedRuns() {
    Bytes style(ValueCodec<CellStyle>::encodedSize(CellStyle{}));
    std::span<Byte> output{style};

    ValueCodec<CellStyle>::encode(CellStyle{}, output);

    const auto run = [&](Byte header, bool styled, Bytes tail) {
      return concatenated({Bytes{static_cast<Byte>(header | (styled ? 0x80 : 0))}, styled ? style : Bytes{}, std::move(tail)});
    };

    // Reads every cell of `bytes`, held in an exactly sized heap block, and each cell's text, as
    // a client copies it into its grid; nullopt when the reader refused the run.
    const auto cells = [](const Bytes& bytes, std::uint32_t count) {
      const auto copy = std::make_unique<Byte[]>(bytes.size());

      std::memcpy(copy.get(), bytes.data(), bytes.size());
      CellReader reader{std::span<const Byte>{copy.get(), bytes.size()}, count};
      std::size_t read = 0;
      unsigned sum = 0;

      try {
        while (const auto cell = reader.next()) {
          for (const auto byte : cell->text) {
            sum += byte;
          }

          ++read;
        }
      } catch (const EncodingError&) {
        return ds::Option<std::size_t>{};
      }

      static_cast<void>(sum);
      return ds::Option<std::size_t>{read};
    };

    constexpr Byte single = 1 << 5;

    check(cells(run(single | 1, true, {'a'}), 1) == 1);
    check(!cells(run(single | 1, false, {'a'}), 1));
    check(!cells(run(single | 5, true, {'a', 'b'}), 2));
    check(!cells(run(single | 1, true, {'a', 'b'}), 1));
    check(!cells(run(0 | 1, true, {'a'}), 1));
    check(!cells(run(3 << 5 | 1, true, {'a'}), 1));
  }

  ClientLayoutNode pane(std::uint64_t id) {
    return ClientLayoutPane{.pane_id = id};
  }

  Bytes node(const ClientLayoutNode& value) {
    Bytes bytes(BodySchema<ClientLayoutNode>::encodedSize(value));
    std::span<Byte> output{bytes};

    BodySchema<ClientLayoutNode>::encodeBody(value, output);
    return bytes;
  }

  // A layout is also a token users paste back in, so the tree it describes is checked when it is
  // decoded: complete, with each pane once, the focus in it and at most 127 nodes.
  void testClientLayoutRejectsMalformedTrees() {
    const ClientLayoutNode split = ClientLayoutSplit{.axis = ClientLayoutAxis::vertical, .ratio = 5000};
    const ds::Array nodes{split, pane(1), pane(2)};
    const TabLocation location{.workspace = {.id = 1}, .tab_id = 1};
    const auto layout = [&](std::uint64_t focused) {
      const ds::Array tabs{ClientTabLayout{.location = location, .focused_pane = focused, .workspace_active = true, .nodes = nodes}};

      return encoded(UpdateClientLayout{.sidebar_visible = true, .sidebar_width = 30, .active_tab = location, .tabs = tabs});
    };

    const auto bytes = layout(1);
    const auto tree = concatenated({node(split), node(pane(1)), node(pane(2))});

    check(!refused<UpdateClientLayout>(bytes));
    check(refused<UpdateClientLayout>(patched(bytes, tree, concatenated({node(split), node(pane(1)), node(pane(1))}))));
    check(refused<UpdateClientLayout>(patched(bytes, tree, concatenated({node(pane(1)), node(split), node(pane(2))}))));

    auto focus = bytes;

    focus[differingByte(bytes, layout(2))] = 9;
    check(refused<UpdateClientLayout>(focus));

    // The node count precedes the nodes: the tree without its last pane, and one of 129 nodes,
    // the fewest that hold 65 panes.
    const auto at = find(bytes, tree);
    const auto count = [&](Bytes changed, std::uint16_t nodes_count) {
      check(changed[at - 2] == 3 && changed[at - 1] == 0, "the node count precedes the nodes");
      changed[at - 2] = static_cast<Byte>(nodes_count);
      changed[at - 1] = static_cast<Byte>(nodes_count >> 8);
      return changed;
    };

    auto missing = count(bytes, 2);

    missing.erase(missing.begin() + static_cast<std::ptrdiff_t>(at + node(split).size() + node(pane(1)).size()), missing.begin() + static_cast<std::ptrdiff_t>(at + tree.size()));
    check(refused<UpdateClientLayout>(missing));

    Bytes many;

    for (std::uint64_t index = 0; index < 64; ++index) {
      many = concatenated({many, node(split)});
    }

    for (std::uint64_t index = 1; index <= 65; ++index) {
      many = concatenated({many, node(pane(index))});
    }

    check(refused<UpdateClientLayout>(patched(count(bytes, 129), tree, many)));
  }

  GraphicsImage image(ImageFormat format, std::uint32_t width, std::uint32_t height, std::uint64_t byte_len) {
    return {.header = {.pane_id = 1, .revision = 1}, .image = {.key = {.image_id = 1, .generation = 1}, .format = format, .width = width, .height = height, .byte_len = byte_len}};
  }

  // Clients allocate and fill exactly `byte_len` bytes for an image and upload width x height
  // pixels, so the two must agree, under a 256 MiB cap.
  void testImageDescriptionRejectsMismatchedLength() {
    check(!encodeRefused(image(ImageFormat::rgb, 3, 5, 45)));
    check(!encodeRefused(image(ImageFormat::rgba, 3, 5, 60)));
    check(encodeRefused(image(ImageFormat::rgb, 3, 5, 46)));
    check(encodeRefused(image(ImageFormat::rgba, 3, 5, 45)));
    check(encodeRefused(image(ImageFormat::rgba, 16384, 16385, std::uint64_t{16384} * 16385 * 4)));
    check(!encodeRefused(image(ImageFormat::rgba, 16384, 4096, std::uint64_t{16384} * 4096 * 4)));

    const auto bytes = encoded(image(ImageFormat::rgb, 3, 5, 45));
    const Bytes length{45, 0, 0, 0, 0, 0, 0, 0};
    const Bytes wrong{46, 0, 0, 0, 0, 0, 0, 0};

    check(!refused<GraphicsImage>(bytes));
    check(refused<GraphicsImage>(patched(bytes, length, wrong)));
  }

  OpenPane openPane(const Launch& launch) {
    return {
        .request_id = 7,
        .target = {},
        .size = {.cols = 80, .rows = 24, .cell_width_px = 8, .cell_height_px = 16},
        .launch = launch,
    };
  }

  // Launch text reaches execve as C strings, so an argument or cwd with an embedded NUL is
  // refused on decode rather than cut short there.
  void testLaunchTextRejectsEmbeddedNul() {
    const ds::Array<std::string_view, 2> arguments{"sh", "nul-sentinel"};
    const auto bytes = encoded(openPane(Launch{.cwd = "/nul-cwd-sentinel", .arguments = arguments}));

    check(!refused<OpenPane>(bytes));
    check(refused<OpenPane>(patched(bytes, text("nul-sentinel"), text(std::string_view{"nul\0sentinel", 12}))));
    check(refused<OpenPane>(patched(bytes, text("nul-cwd-sentinel"), text(std::string_view{"nul\0cwd-sentinel", 16}))));
  }

  // A message whose body would pass the frame limit is refused when encoded, rather than sent
  // as a frame every peer drops along with the connection: a page of history results whose
  // commands are each at their 64 KiB bound passes it after 64 entries.
  void testOversizedEncodeIsRefused() {
    const std::string command(64 * 1024, 'a');
    std::vector<HistoryEntry> entries(64, HistoryEntry{.id = 1, .pane_id = 1, .command = command});

    check(encodeRefused(HistoryResults{.request_id = 1, .entries = entries}));
    check(!encodeRefused(HistoryResults{.request_id = 1, .entries = std::span{entries}.first(60)}));
  }

  // Codec::decode holds a decoded message to the invariants its sender's encode checks: each
  // case is a valid encoding with one field patched to a value encode refuses.
  void testDecodeEnforcesMessageInvariants() {
    const auto session = encoded(ReportAgentSession{.request_id = 1, .pane_id = 1, .pane_generation = 1, .session = "zession_a"});

    check(!refused<ReportAgentSession>(session));
    check(refused<ReportAgentSession>(patched(session, text("zession_a"), text("-ession_a"))));
    check(refused<ReportAgentSession>(patched(session, text("zession_a"), text("zession/a"))));

    const ds::Array<std::string_view, 2> arguments{"argv0-sentinel", "-c"};
    const ds::Array<EnvironmentEntry, 1> environment{{{"ENVQNAME", "1"}}};
    const auto pane = encoded(openPane(Launch{.cwd = "/", .arguments = arguments, .environment_mode = EnvironmentMode::replace, .environment = environment}));
    const Bytes empty_argument{0, 0};

    check(!refused<OpenPane>(pane));
    check(refused<OpenPane>(patched(pane, text("ENVQNAME"), text("ENV=NAME"))));
    check(refused<OpenPane>(patched(pane, concatenated({{14, 0}, text("argv0-sentinel")}), empty_argument)));

    const ds::Array<std::string_view, 1> command{"exec-sentinel"};
    const auto execution = encoded(ExecutionRequest{.request_id = 1, .action = ExecutionAction::start, .execution_id = 1, .cwd = "/", .arguments = command});

    check(!refused<ExecutionRequest>(execution));
    check(refused<ExecutionRequest>(patched(execution, concatenated({{1, 13, 0}, text("exec-sentinel")}), Bytes{0})));

    const auto editor = encoded(OpenEditor{.request_id = 1, .pane_id = 1, .pane_generation = 1, .editor = "vim", .path = "/editor-sentinel"});

    check(!refused<OpenEditor>(editor));
    check(refused<OpenEditor>(patched(editor, text("/editor-sentinel"), text("xeditor-sentinel"))));
  }

#ifdef TELAR_DEBUG
  // The debug printer names each field and shows its value, escaping text, with its scratch text in
  // the allocator it is given and none of it left behind.
  void testPrettyPrintNamesFields() {
    SystemAllocator system;
    BudgetAllocator memory{system, 1 << 20};
    std::FILE* output = std::tmpfile();

    check(output != nullptr);
    Codec::pretty_print(memory, CompleteWords{.request_id = 7, .pane_id = 3, .provider = CompletionProvider::branch, .prefix = "gi\"t"}, output);
    check(memory.liveBytes() == 0, "the printer returns its text to the allocator");

    ds::Array<char, 4096> printed{};

    std::rewind(output);
    const auto size = std::fread(printed.dataMut(), 1, printed.size() - 1, output);

    std::fclose(output);
    const std::string_view text{printed.data(), size};

    check(text.starts_with("Frame:\n") && text.contains("request_id") && text.contains("pane_id") && text.contains("prefix"), "every field is named");
    check(text.contains("7") && text.contains("\"gi\\x22t\""), "values are shown, quotes escaped");
  }

  const telar::testing::Case case_pretty_print{"wire.pretty_print_names_fields", testPrettyPrintNamesFields};
#endif

  const telar::testing::Case case_truncated{"wire.truncated_payload_is_rejected_at_every_cut", testTruncatedPayloadIsRejectedAtEveryCut};
  const telar::testing::Case case_storage{"wire.decode_storage_exhaustion_is_refused", testDecodeStorageExhaustionIsRefused};
  const telar::testing::Case case_enum_bytes{"wire.enum_bytes_beyond_range_are_rejected", testEnumBytesBeyondRangeAreRejected};
  const telar::testing::Case case_notification_link{"wire.notification_link_rejects_unsafe_urls", testNotificationLinkRejectsUnsafeUrls};
  const telar::testing::Case case_metadata_round_trip{"wire.frame_metadata_hyperlinks_round_trip", testFrameMetadataHyperlinksRoundTrip};
  const telar::testing::Case case_metadata_bounds{"wire.frame_metadata_rejects_out_of_bounds_links", testFrameMetadataRejectsOutOfBoundsLinks};
  const telar::testing::Case case_frame_header{"wire.frame_header_rejects_spans_outside_grid", testFrameHeaderRejectsSpansOutsideGrid};
  const telar::testing::Case case_cell_reader{"wire.cell_reader_rejects_malformed_runs", testCellReaderRejectsMalformedRuns};
  const telar::testing::Case case_client_layout{"wire.client_layout_rejects_malformed_trees", testClientLayoutRejectsMalformedTrees};
  const telar::testing::Case case_image_description{"wire.image_description_rejects_mismatched_length", testImageDescriptionRejectsMismatchedLength};
  const telar::testing::Case case_launch_nul{"wire.launch_text_rejects_embedded_nul", testLaunchTextRejectsEmbeddedNul};
  const telar::testing::Case case_oversized_encode{"wire.oversized_encode_is_refused", testOversizedEncodeIsRefused};
  const telar::testing::Case case_message_invariants{"wire.decode_enforces_message_invariants", testDecodeEnforcesMessageInvariants};

}
