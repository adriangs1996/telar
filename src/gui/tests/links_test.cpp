#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstddef>
#include <cstdint>
#include <cstdio>

import std;
import telar.base.memory;
import telar.client.protocol;
import telar.gui.core.primitives;
import telar.gui.terminal.screen;
import telar.gui.links.cell_links;
import telar.gui.links.path_expansion;

namespace {

using namespace telar;
using namespace telar::gui;

void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

template <std::uint16_t Columns, std::uint16_t Rows>
struct GridFixture {
  std::array<CellValue, static_cast<std::size_t>(Columns) * Rows> cells;
  std::array<Byte, Rows> flags{};
  Scroll scroll{.total_rows = Rows};

  [[nodiscard]] LinkGrid grid() const noexcept {
    return {.cells = cells, .columns = Columns, .rows = Rows, .scroll = scroll, .row_flags = flags};
  }

  void write(std::size_t row, std::string_view text) {
    for (std::size_t column = 0; column < std::min<std::size_t>(Columns, text.size()); ++column) {
      cells[(row * Columns) + column].text[0] = static_cast<Byte>(text[column]);
    }
  }
};

void textRecognition() {
  constexpr std::string_view source = "See [the docs](https://example.com/a(b)) and src/main.cpp:12:3.";
  const auto markdown = MarkdownLinks::extract(source, source.find("docs"));
  require(markdown && markdown->destination.view(source) == "https://example.com/a(b)", "Markdown labels must resolve to their complete URI");
  const auto path = PathRecognizer::extract(source, source.find("main"));
  require(path && path->destination.view(source) == "src/main.cpp:12:3", "prose paths must retain their line and column");
  const auto location = PathRecognizer::locate("src/main.cpp:12:3");
  constexpr std::uint32_t expected_line = 12;
  constexpr std::uint32_t expected_column = 3;
  require(location.path == "src/main.cpp" && location.line == expected_line && location.column == expected_column, "path position suffixes must remain separate argv values");
  const auto fragment = PathRecognizer::fragment("L12C3-L20");
  require(fragment && fragment->line == expected_line && fragment->column == expected_column, "file fragments must use the first position in a range");
  require(!UriRecognizer::classify("https://x:65536") && UriRecognizer::classify("https://x:1_2") == LinkScheme::https, "URI ports must match the original parser's bounds and decimal syntax");
  require(!UriRecognizer::classify("https://x/\xff") && !UriRecognizer::classify("javascript:alert(1)"), "malformed UTF-8 and unsupported schemes must not authorize an external target");
}

void ownedTargets() {
  std::array source{'h', 't', 't', 'p', ':', '/', '/', 'x'};
  auto target = LinkTarget::fromUri({source.data(), source.size()});
  const auto expected = LinkTarget::fromUri("http://x");
  if (!target || !expected) {
    throw std::runtime_error{"The fixture must classify as an HTTP target"};
  }

  source.back() = 'y';
  require(target.value().text() == "http://x", "link targets must own the exact validated bytes");
  const std::array copies{target.value()};
  target.reset();
  require(copies.front() == *expected, "owned targets must preserve scheme and byte identity after the original is destroyed");
  require(!LinkTarget::fromUri("src/main.cpp:12") && LinkTarget::fromPath("src/main.cpp:12").has_value(), "local paths must remain distinct from URI schemes");
  require(!LinkTarget::fromPath("a\nb") && !LinkTarget::fromPath("\xff"), "local targets must reject controls and malformed UTF-8");
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
  require(found && found->target.text() == "https://example.com" && found->start == CellPosition{.y = offset} && found->end == CellPosition{.x = static_cast<std::uint16_t>(second_row.size()), .y = offset + 1}, "VT-confirmed soft wraps must yield one URI and its absolute cell interval");
  fixture.flags = {};
  require(!CellLinks::match(fixture.grid(), {.x = 2, .y = offset + 1}), "hard newlines must not join neighboring text into a URI");
  fixture.flags = {static_cast<Byte>(RowFlag::wrap) | static_cast<Byte>(RowFlag::continuation), static_cast<Byte>(RowFlag::continuation)};
  require(!CellLinks::match(fixture.grid(), {.x = 2, .y = offset + 1}), "a link truncated at the top viewport boundary must not become a shorter destination");
  fixture.write(0, "http://x/aaa");
  fixture.write(1, "aaaaaaaaaaaa");
  fixture.flags = {static_cast<Byte>(RowFlag::wrap), static_cast<Byte>(RowFlag::continuation) | static_cast<Byte>(RowFlag::wrap)};
  require(!CellLinks::match(fixture.grid(), {.x = 2, .y = offset + 1}), "a link continuing below the viewport must not authorize its truncated prefix");
}

void wideCells() {
  constexpr std::uint16_t columns = 16;
  GridFixture<columns, 1> fixture;
  fixture.write(0, "http://x/");
  constexpr std::size_t ideograph_column = 9;
  fixture.cells[ideograph_column] = CellValue{Cell{.width = CellWidth::wide, .text = byteView("中")}};
  fixture.cells[ideograph_column + 1] = CellValue{Cell{.width = CellWidth::continuation}};
  const auto first = CellLinks::match(fixture.grid(), {.x = ideograph_column});
  const auto continuation = CellLinks::match(fixture.grid(), {.x = ideograph_column + 1});
  require(first && continuation && *first == *continuation && first->target.text() == "http://x/中" && first->end.x == ideograph_column + 2, "wide-cell continuations must share the leading cell's URI and complete extent");
  fixture.cells.front().width = CellWidth::continuation;
  require(!CellLinks::match(fixture.grid(), {}), "an orphan continuation must not resolve to an unrelated cell");

  constexpr std::uint16_t padded_columns = 8;
  GridFixture<padded_columns, 2> padded;
  padded.write(0, "https:/");
  padded.write(1, "/x");
  padded.flags = {static_cast<Byte>(RowFlag::wrap) | static_cast<Byte>(RowFlag::wide_padding), static_cast<Byte>(RowFlag::continuation)};
  const auto joined = CellLinks::match(padded.grid(), {.x = 1, .y = 1});
  require(joined && joined->target.text() == "https://x" && joined->end == CellPosition{.x = 2, .y = 1}, "wide-glyph padding must not insert a space into logical text");
  require(!CellLinks::match(padded.grid(), {.x = padded_columns - 1}), "padding cells must not become clickable targets");
}

void metadataAuthority() {
  SystemAllocator memory;
  Screen screen{memory};
  constexpr std::string_view label = "https://label.test";
  constexpr std::string_view destination = "https://destination.test";
  std::vector<Cell> cells;
  for (const auto &byte : label) {
    cells.push_back(Cell{.text = byteView({&byte, 1})});
  }

  constexpr std::size_t encoded_capacity = 4096;
  std::array<Byte, encoded_capacity> encoded{};
  const std::array spans{FrameSpan{.count = static_cast<std::uint32_t>(cells.size()), .cells = CellRunCodec::encode(cells, encoded)}};
  std::array<Byte, 1> flags{static_cast<Byte>(RowFlag::hyperlinks)};
  const std::array links{MetadataLink{.len = destination.size()}};
  const std::array runs{MetadataRun{.len = static_cast<std::uint32_t>(cells.size())}};
  PaneFrame frame;
  frame.pane_id = frame.frame_id = 1;
  frame.cols = label.size();
  frame.rows = 1;
  frame.scroll.total_rows = 1;
  frame.spans = spans;
  frame.text_metadata = TextMetadata{.row_flags = flags, .links = links, .runs = runs, .uris = byteView(destination)};
  static_cast<void>(screen.apply(frame));
  const auto found = CellLinks::resolve(screen, {.x = 1});
  require(found && found->target.text() == destination && found->metadata_index == 0 && found->end.x == frame.cols, "OSC 8 metadata must take precedence over a URI-shaped label");
  const auto textual = CellLinks::text(screen, {.x = 1});
  require(textual && textual->target.text() == label && !textual->metadata_index, "text-only copy-cursor extraction must retain its original metadata-independent policy");

  ++frame.frame_id;
  frame.text_metadata = TextMetadata{.status = MetadataStatus::partial, .row_flags = flags};
  static_cast<void>(screen.apply(frame));
  require(!CellLinks::resolve(screen, {.x = 1}), "dropped OSC 8 metadata must not let the displayed label authorize a different destination");
  ++frame.frame_id;
  flags.front() = 0;
  frame.text_metadata = TextMetadata{.status = MetadataStatus::omitted, .row_flags = flags};
  static_cast<void>(screen.apply(frame));
  const auto plain = CellLinks::resolve(screen, {.x = 1});
  require(plain && plain->target.text() == label, "omitted metadata without hyperlinks must still permit visible text recognition");
}

}

int main() {
  try {
    textRecognition();
    ownedTargets();
    softWraps();
    wideCells();
    metadataAuthority();
    std::puts("gui-links: passed");
  } catch (const std::exception &error) {
    std::cerr << "gui-links: " << error.what() << '\n';

    return 1;
  }
}
