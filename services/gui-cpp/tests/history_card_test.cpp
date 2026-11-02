#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include "core/unicode_scalar.hpp"
#include "presentation/history_card.hpp"
#include "presentation/history_match_highlight.hpp"
#include "presentation/history_row_geometry.hpp"
#include "text/grapheme_cursor.hpp"
#include "text/wrapped_lines.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <exception>
#include <iostream>
#include <stdexcept>
#include <string>
#include <string_view>

namespace {

using namespace telar::gui;

void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

void wordWrappingBorrowsCompleteLines() {
  constexpr std::string_view source = "one two three";
  constexpr std::uint16_t columns = 8;
  WrappedLines words{source, columns, true};
  require(words.next() == "one two ", "word wrapping must retain the separating space");
  const auto last = words.next();
  require(last == "three" && last->data() == source.data() + columns, "wrapped lines must borrow their command storage");
  require(!words.next(), "the final line must be returned exactly once");

  WrappedLines breaks{"first\r\n\r\nlast\n", columns};
  require(breaks.next() == "first" && breaks.next() == "" && breaks.next() == "last" && breaks.next() == "", "CRLF and trailing blank lines must preserve their original count");
  require(!breaks.next(), "a trailing blank line must finish the iterator");
}

void graphemesAndInvalidBytesKeepTheirBoundaries() {
  WrappedLines emoji{"👩🏽‍💻á", 1, true};
  require(emoji.next() == "👩🏽‍💻", "a cluster wider than the line must make progress without splitting its bytes");
  require(emoji.next() == "á" && !emoji.next(), "combining marks must stay attached to their base");
  constexpr std::string_view malformed = "a\xff"
                                         "b";
  WrappedLines bytes{malformed, 2};
  require(bytes.next() == malformed.substr(0, 2) && bytes.next() == "b", "wrapping must borrow invalid input while counting replacement cells");
  GraphemeCursor replacing{malformed};
  require(replacing.nextReplacingInvalid() == "a" && replacing.nextReplacingInvalid() == "�" && replacing.columns() == 1 && replacing.nextReplacingInvalid() == "b", "replacement iteration must consume one invalid byte per cell");
  GraphemeCursor strict{malformed};
  try {
    static_cast<void>(strict.next());
  } catch (const std::invalid_argument &) {
    return;
  }

  throw std::runtime_error{"The strict grapheme reader must retain its rejection policy"};
}

void strictAndNonthrowingScalarReadsAgree() {
  struct InvalidScalar {
    std::string_view text;
    std::string_view message;
  };

  constexpr std::array invalid{
      InvalidScalar{.text = "", .message = "Expected one UTF-8 scalar"},
      InvalidScalar{.text = "abcde", .message = "Expected one UTF-8 scalar"},
      InvalidScalar{.text = "\x80", .message = "Invalid UTF-8 leading byte"},
      InvalidScalar{.text = "\xc2x", .message = "Invalid UTF-8 continuation byte"},
      InvalidScalar{.text = "\xc0\x80", .message = "Invalid or overlong UTF-8 scalar"},
      InvalidScalar{.text = "\xed\xa0\x80", .message = "Invalid or overlong UTF-8 scalar"},
  };
  for (const auto sample : invalid) {
    require(!Utf8Scalar::tryDecode(sample.text), "a nonthrowing scalar read must reject every invalid sequence");
    try {
      static_cast<void>(Utf8Scalar::decode(sample.text));
      throw std::runtime_error{"The strict scalar reader accepted an invalid sequence"};
    } catch (const std::invalid_argument &error) {
      require(sample.message == error.what(), "the strict reader must retain its original rejection messages");
    }
  }

  constexpr std::array<std::string_view, 4> valid{"a", "é", "中", "👩"};
  for (const auto text : valid) {
    require(Utf8Scalar::tryDecode(text) == Utf8Scalar::decode(text), "both scalar readers must decode every valid sequence identically");
  }
}

void cardsBoundTheRemainingLineCount() {
  constexpr ChromeMetrics chrome;
  constexpr Rect bounds{.width = 800, .height = 34};
  const auto row = HistoryRowGeometry::derive(bounds, chrome, bounds.height, {.expanded = true});
  constexpr HistoryCardMetrics metrics{.cell_width = 8, .cell_height = 20, .row_height = bounds.height, .viewport_height = 800};
  constexpr std::size_t command_bytes = 100'000;
  const std::string command(command_bytes, '\n');
  const auto card = HistoryCard::measure(row, chrome, metrics, command);
  require(card.shown == HistoryCard::maximum_lines && card.more == HistoryCard::more_bound, "a long command must count only the visible lines and bounded remainder");
  require(card.lines.front().data() == command.data(), "card lines must borrow command storage");
  require(card.meta.y >= card.text_y + (static_cast<float>(card.shown) * metrics.cell_height), "metadata must remain below the wrapped command");
  require(card.height <= metrics.viewport_height, "the selected card must remain inside the list viewport");
}

void highlightsContinueAcrossVisibleLines() {
  HistoryMatchHighlight highlight{"中bS"};
  constexpr float cell_width = 8;
  constexpr Rect first{.x = 10, .y = 20, .width = 100, .height = 20};
  constexpr Rect second{.x = 10, .y = 40, .width = 100, .height = 20};
  std::array<Rect, 3> matches{};
  std::size_t count = 0;
  auto record = [&](Rect area, std::string_view) {
    matches.at(count++) = area;
  };
  highlight.paint("á中B", first, cell_width, record);
  highlight.paint("second", second, cell_width, record);
  constexpr std::size_t matched_bytes = std::string_view{"中bS"}.size();
  require(count == matches.size() && highlight.matched() == matched_bytes, "matching must preserve UTF-8 byte positions and ASCII case folding across lines");
  require(matches.front().width == 2 * cell_width && matches.back().y == second.y, "wide clusters and the next line must retain their complete cell rectangles");
  HistoryMatchHighlight clipped{"中"};
  constexpr Rect narrow{.width = cell_width, .height = 20};
  clipped.paint("中", narrow, cell_width, record);
  require(clipped.matched() == 0 && count == matches.size(), "an invisible partial cluster must not consume a query match");
}

}

int main() try {
  wordWrappingBorrowsCompleteLines();
  graphemesAndInvalidBytesKeepTheirBoundaries();
  strictAndNonthrowingScalarReadsAgree();
  cardsBoundTheRemainingLineCount();
  highlightsContinueAcrossVisibleLines();
  std::puts("gui-history-card: passed");

  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
