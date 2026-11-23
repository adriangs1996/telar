#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstddef>
#include <cstdint>

import std;
import telar.testing;
import telar.testing.test_memory;
import telar.base.memory.allocators;
import telar.gui.foundation.core;
import telar.gui.foundation.terminal;
import telar.gui.features.terminal.links;
import telar.wire.pane_io;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::terminal::links;

  template <std::uint16_t Columns, std::uint16_t Rows>
  struct GridFixture {
    ds::Array<CellValue, static_cast<std::size_t>(Columns) * Rows> cells;
    ds::Array<Byte, Rows> flags{};
    Scroll scroll{.total_rows = Rows};

    [[nodiscard]] LinkGrid grid() const noexcept {
      return {.cells = cells, .columns = Columns, .rows = Rows, .scroll = scroll, .row_flags = flags};
    }

    void write(std::size_t row, std::string_view text) {
      for (std::size_t column = 0; column < std::min<std::size_t>(Columns, text.size()); ++column) {
        cells.atMut((row * Columns) + column).text.atMut(0) = static_cast<Byte>(text[column]);
      }
    }
  };

  void textRecognition() {
    constexpr std::string_view source = "See [the docs](https://example.com/a(b)) and src/main.cpp:12:3.";
    const auto markdown = MarkdownLinks::extract(source, source.find("docs"));

    check(markdown && markdown->destination.view(source) == "https://example.com/a(b)", "Markdown labels must resolve to their complete URI");
    const auto path = PathRecognizer::extract(source, source.find("main"));

    check(path && path->destination.view(source) == "src/main.cpp:12:3", "prose paths must retain their line and column");
    const auto location = PathRecognizer::locate("src/main.cpp:12:3");
    constexpr std::uint32_t expected_line = 12;
    constexpr std::uint32_t expected_column = 3;

    check(location.path == "src/main.cpp" && location.line == expected_line && location.column == expected_column, "path position suffixes must remain separate argv values");
    const auto fragment = PathRecognizer::fragment("L12C3-L20");

    check(fragment && fragment->line == expected_line && fragment->column == expected_column, "file fragments must use the first position in a range");
    check(!UriRecognizer::classify("https://x:65536") && UriRecognizer::classify("https://x:1_2") == LinkScheme::https, "URI ports must match the original parser's bounds and decimal syntax");
    check(!UriRecognizer::classify("https://x/\xff") && !UriRecognizer::classify("javascript:alert(1)"), "malformed UTF-8 and unsupported schemes must not authorize an external target");
  }

  void ownedTargets() {
    ds::Array source{'h', 't', 't', 'p', ':', '/', '/', 'x'};
    auto target = LinkTarget::fromUri({source.data(), source.size()});
    const auto expected = LinkTarget::fromUri("http://x");
    if (!target || !expected) {
      throw std::runtime_error{"The fixture must classify as an HTTP target"};
    }

    source.atMut(source.size() - 1) = 'y';
    check(target.get().text() == "http://x", "link targets must own the exact validated bytes");
    const ds::Array copies{target.get()};

    target.reset();
    check(copies.front() == *expected, "owned targets must preserve scheme and byte identity after the original is destroyed");
    check(!LinkTarget::fromUri("src/main.cpp:12") && LinkTarget::fromPath("src/main.cpp:12").hasValue(), "local paths must remain distinct from URI schemes");
    check(!LinkTarget::fromPath("a\nb") && !LinkTarget::fromPath("\xff"), "local targets must reject controls and malformed UTF-8");
  }

  void softWraps() {
    constexpr std::uint16_t columns = 12;
    constexpr std::uint16_t rows = 2;
    GridFixture<columns, rows> fixture;
    constexpr std::uint32_t offset = 5;

    fixture.scroll = {.total_rows = offset + rows, .offset = offset};
    fixture.write(0, "https://exam");
    constexpr std::string_view second_row = "ple.com";

    fixture.write(1, second_row);
    fixture.flags = {static_cast<Byte>(RowFlag::wrap), static_cast<Byte>(RowFlag::continuation)};
    const auto found = CellLinks::match(fixture.grid(), {.x = 2, .y = offset + 1});

    check(found && found->target.text() == "https://example.com" && found->start == CellPosition{.y = offset} && found->end == CellPosition{.x = static_cast<std::uint16_t>(second_row.size()), .y = offset + 1}, "VT-confirmed soft wraps must yield one URI and its absolute cell interval");
    fixture.flags = {};
    check(!CellLinks::match(fixture.grid(), {.x = 2, .y = offset + 1}), "hard newlines must not join neighboring text into a URI");
    fixture.flags = {static_cast<Byte>(RowFlag::wrap) | static_cast<Byte>(RowFlag::continuation), static_cast<Byte>(RowFlag::continuation)};
    check(!CellLinks::match(fixture.grid(), {.x = 2, .y = offset + 1}), "a link truncated at the top viewport boundary must not become a shorter destination");
    fixture.write(0, "http://x/aaa");
    fixture.write(1, "aaaaaaaaaaaa");
    fixture.flags = {static_cast<Byte>(RowFlag::wrap), static_cast<Byte>(RowFlag::continuation) | static_cast<Byte>(RowFlag::wrap)};
    check(!CellLinks::match(fixture.grid(), {.x = 2, .y = offset + 1}), "a link continuing below the viewport must not authorize its truncated prefix");
  }

  void wideCells() {
    constexpr std::uint16_t columns = 16;
    GridFixture<columns, 1> fixture;

    fixture.write(0, "http://x/");
    constexpr std::size_t ideograph_column = 9;

    fixture.cells.atMut(ideograph_column) = CellValue{Cell{.width = CellWidth::wide, .text = byteView("中")}};
    fixture.cells.atMut(ideograph_column + 1) = CellValue{Cell{.width = CellWidth::continuation}};
    const auto first = CellLinks::match(fixture.grid(), {.x = ideograph_column});
    const auto continuation = CellLinks::match(fixture.grid(), {.x = ideograph_column + 1});

    check(first && continuation && *first == *continuation && first->target.text() == "http://x/中" && first->end.x == ideograph_column + 2, "wide-cell continuations must share the leading cell's URI and complete extent");
    fixture.cells.atMut(0).width = CellWidth::continuation;
    check(!CellLinks::match(fixture.grid(), {}), "an orphan continuation must not resolve to an unrelated cell");

    constexpr std::uint16_t padded_columns = 8;
    GridFixture<padded_columns, 2> padded;

    padded.write(0, "https:/");
    padded.write(1, "/x");
    padded.flags = {static_cast<Byte>(RowFlag::wrap) | static_cast<Byte>(RowFlag::wide_padding), static_cast<Byte>(RowFlag::continuation)};
    const auto joined = CellLinks::match(padded.grid(), {.x = 1, .y = 1});

    check(joined && joined->target.text() == "https://x" && joined->end == CellPosition{.x = 2, .y = 1}, "wide-glyph padding must not insert a space into logical text");
    check(!CellLinks::match(padded.grid(), {.x = padded_columns - 1}), "padding cells must not become clickable targets");
  }

  void metadataAuthority() {
    telar::testing::TestMemory memory;
    Screen<telar::ConcurrentMemory> screen{memory};
    constexpr std::string_view label = "https://label.test";
    constexpr std::string_view destination = "https://destination.test";
    std::vector<Cell> cells;

    for (const auto& byte : label) {
      cells.push_back(Cell{.text = byteView({&byte, 1})});
    }

    constexpr std::size_t encoded_capacity = 4096;
    ds::Array<Byte, encoded_capacity> encoded{};
    const ds::Array spans{FrameSpan{.count = static_cast<std::uint32_t>(cells.size()), .cells = CellRunCodec::encode(cells, encoded.viewMut())}};
    ds::Array<Byte, 1> flags{static_cast<Byte>(RowFlag::hyperlinks)};
    const ds::Array links{MetadataLink{.len = destination.size()}};
    const ds::Array runs{MetadataRun{.len = static_cast<std::uint32_t>(cells.size())}};
    PaneFrame frame;

    frame.pane_id = frame.frame_id = 1;
    frame.cols = label.size();
    frame.rows = 1;
    frame.scroll.total_rows = 1;
    frame.spans = spans;
    frame.text_metadata = TextMetadata{.row_flags = flags, .links = links, .runs = runs, .uris = byteView(destination)};
    static_cast<void>(screen.apply(frame));
    const auto found = CellLinks::resolve(screen, {.x = 1});

    check(found && found->target.text() == destination && found->metadata_index == 0 && found->end.x == frame.cols, "OSC 8 metadata must take precedence over a URI-shaped label");
    const auto textual = CellLinks::text(screen, {.x = 1});

    check(textual && textual->target.text() == label && !textual->metadata_index, "text-only copy-cursor extraction must retain its original metadata-independent policy");

    ++frame.frame_id;
    frame.text_metadata = TextMetadata{.status = MetadataStatus::partial, .row_flags = flags};
    static_cast<void>(screen.apply(frame));
    check(!CellLinks::resolve(screen, {.x = 1}), "dropped OSC 8 metadata must not let the displayed label authorize a different destination");
    ++frame.frame_id;
    flags.atMut(0) = 0;
    frame.text_metadata = TextMetadata{.status = MetadataStatus::omitted, .row_flags = flags};
    static_cast<void>(screen.apply(frame));
    const auto plain = CellLinks::resolve(screen, {.x = 1});

    check(plain && plain->target.text() == label, "omitted metadata without hyperlinks must still permit visible text recognition");
  }

  // A development server's link names a port of the machine that printed it, which a pane of
  // another machine reaches through a port here.
  void linksToAPortOfTheirMachineAreRewrittenThroughAForward() {
    // A text the terminal would not take for a link at all names no port either.
    const auto link = [](std::string_view text) -> telar::ds::Option<LocalPortLink> {
      const auto target = LinkTarget::fromUri(text);

      return target ? LocalPortLink::parse(*target) : telar::ds::none;
    };
    const auto through = [&](std::string_view text, std::uint16_t local) {
      return std::string{link(text)->through(local)->text()};
    };

    for (const std::string_view local : {"http://localhost:3000/", "https://localhost/app", "http://127.0.0.1", "http://[::1]:5173/x?y#z", "https://LOCALHOST", "http://0.0.0.0:8000/docs"}) {
      check(link(local).hasValue(), local);
    }

    check(link("http://localhost:3000/")->port() == 3000);
    check(link("https://localhost/app")->port() == 443 && link("http://127.0.0.1")->port() == 80, "a link without a port names its scheme's own");
    check(link("http://[::1]:5173/x?y#z")->port() == 5173);
    check(through("http://localhost:3000/a/b?c=1#d", 3000) == "http://localhost:3000/a/b?c=1#d", "the same port here leaves the link as it was");
    check(through("http://localhost:3000/a/b?c=1#d", 41234) == "http://localhost:41234/a/b?c=1#d");
    check(through("https://LOCALHOST", 8443) == "https://LOCALHOST:8443");
    check(through("http://[::1]:5173/", 6000) == "http://[::1]:6000/");
    check(through("http://0.0.0.0:8000/docs", 8000) == "http://localhost:8000/docs", "every interface there is this machine's loopback here");
    for (const std::string_view other : {"http://example.com:3000/", "http://localhost.example.com/", "http://user@localhost:3000/", "http://localhost:0/", "http://localhost:99999/", "http://192.168.1.5:3000/", "ssh://localhost:22"}) {
      check(!link(other).hasValue(), "only a plain link to the machine's own loopback is forwarded");
    }
  }

  const telar::testing::Case case_text_recognition{"links.text_recognition", textRecognition};
  const telar::testing::Case case_owned_targets{"links.owned_targets", ownedTargets};
  const telar::testing::Case case_soft_wraps{"links.soft_wraps", softWraps};
  const telar::testing::Case case_wide_cells{"links.wide_cells", wideCells};
  const telar::testing::Case case_metadata_authority{"links.metadata_authority", metadataAuthority};

  const telar::testing::Case case_links_to_a_port_of_their_machine_are_rewritten_through_a_forward{"links.links_to_a_port_of_their_machine_are_rewritten_through_a_forward", linksToAPortOfTheirMachineAreRewrittenThroughAForward};

}
