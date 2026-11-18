#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstddef>
#include <cstdint>

import std;
import telar.testing;
import telar.gui.foundation.core;
import telar.gui.foundation.forms;
import telar.gui.foundation.text;
import telar.gui.features.history;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar::gui;

  void wordWrappingBorrowsCompleteLines() {
    constexpr std::string_view source = "one two three";
    constexpr std::uint16_t columns = 8;
    WrappedLines words{source, columns, true};

    check(words.next() == "one two ", "word wrapping must retain the separating space");
    const auto last = words.next();

    check(last == "three" && last->data() == source.data() + columns, "wrapped lines must borrow their command storage");
    check(!words.next(), "the final line must be returned exactly once");

    WrappedLines breaks{"first\r\n\r\nlast\n", columns};

    check(breaks.next() == "first" && breaks.next() == "" && breaks.next() == "last" && breaks.next() == "", "CRLF and trailing blank lines must preserve their original count");
    check(!breaks.next(), "a trailing blank line must finish the iterator");
  }

  void graphemesAndInvalidBytesKeepTheirBoundaries() {
    WrappedLines emoji{"👩🏽‍💻á", 1, true};

    check(emoji.next() == "👩🏽‍💻", "a cluster wider than the line must make progress without splitting its bytes");
    check(emoji.next() == "á" && !emoji.next(), "combining marks must stay attached to their base");
    constexpr std::string_view malformed = "a\xff"
                                           "b";
    WrappedLines bytes{malformed, 2};

    check(bytes.next() == malformed.substr(0, 2) && bytes.next() == "b", "wrapping must borrow invalid input while counting replacement cells");
    GraphemeCursor replacing{malformed};

    check(replacing.nextReplacingInvalid() == "a" && replacing.nextReplacingInvalid() == "�" && replacing.columns() == 1 && replacing.nextReplacingInvalid() == "b", "replacement iteration must consume one invalid byte per cell");
    GraphemeCursor strict{malformed};

    try {
      static_cast<void>(strict.next());
    } catch (const std::invalid_argument&) {
      return;
    }

    throw std::runtime_error{"The strict grapheme reader must retain its rejection policy"};
  }

  void strictAndNonthrowingScalarReadsAgree() {
    struct InvalidScalar {
      std::string_view text;
      std::string_view message;
    };

    constexpr telar::ds::Array invalid{
        InvalidScalar{.text = "", .message = "Expected one UTF-8 scalar"},
        InvalidScalar{.text = "abcde", .message = "Expected one UTF-8 scalar"},
        InvalidScalar{.text = "\x80", .message = "Invalid UTF-8 leading byte"},
        InvalidScalar{.text = "\xc2x", .message = "Invalid UTF-8 continuation byte"},
        InvalidScalar{.text = "\xc0\x80", .message = "Invalid or overlong UTF-8 scalar"},
        InvalidScalar{.text = "\xed\xa0\x80", .message = "Invalid or overlong UTF-8 scalar"},
    };

    for (const auto sample : invalid) {
      check(!Utf8Scalar::tryDecode(sample.text), "a nonthrowing scalar read must reject every invalid sequence");
      try {
        static_cast<void>(Utf8Scalar::decode(sample.text));
        throw std::runtime_error{"The strict scalar reader accepted an invalid sequence"};
      } catch (const std::invalid_argument& error) {
        check(sample.message == error.what(), "the strict reader must retain its original rejection messages");
      }
    }

    constexpr telar::ds::Array<std::string_view, 4> valid{"a", "é", "中", "👩"};

    for (const auto text : valid) {
      check(Utf8Scalar::tryDecode(text) == Utf8Scalar::decode(text), "both scalar readers must decode every valid sequence identically");
    }
  }

  void cardsBoundTheRemainingLineCount() {
    constexpr ChromeMetrics chrome;
    constexpr Rect bounds{.width = 800, .height = 34};
    const auto row = features::history::HistoryRowGeometry::derive(bounds, chrome, bounds.height, {.expanded = true});
    constexpr features::history::HistoryCardMetrics metrics{.cell_width = 8, .cell_height = 20, .row_height = bounds.height, .viewport_height = 800};
    constexpr std::size_t command_bytes = 100'000;
    const std::string command(command_bytes, '\n');
    const auto card = features::history::HistoryCard::measure(row, chrome, metrics, command);

    check(card.shown == features::history::HistoryCard::maximum_lines && card.more == features::history::HistoryCard::more_bound, "a long command must count only the visible lines and bounded remainder");
    check(features::history::HistoryCard::line(command, card.lines.front()).data() == command.data(), "card lines must lie in the command they were measured over");
    check(card.meta.y >= card.text_y + (static_cast<float>(card.shown) * metrics.cell_height), "metadata must remain below the wrapped command");
    check(card.height <= metrics.viewport_height, "the selected card must remain inside the list viewport");
  }

  void highlightsContinueAcrossVisibleLines() {
    HistoryMatchHighlight highlight{"中bS"};
    constexpr float cell_width = 8;
    constexpr Rect first{.x = 10, .y = 20, .width = 100, .height = 20};
    constexpr Rect second{.x = 10, .y = 40, .width = 100, .height = 20};
    telar::ds::Array<Rect, 3> matches{};
    std::size_t count = 0;
    auto record = [&](Rect area, std::string_view) {
      matches.atCheckedMut(count++) = area;
    };

    highlight.paint("á中B", first, cell_width, record);
    highlight.paint("second", second, cell_width, record);
    constexpr std::size_t matched_bytes = std::string_view{"中bS"}.size();

    check(count == matches.size() && highlight.matched() == matched_bytes, "matching must preserve UTF-8 byte positions and ASCII case folding across lines");
    check(matches.front().width == 2 * cell_width && matches.back().y == second.y, "wide clusters and the next line must retain their complete cell rectangles");
    HistoryMatchHighlight clipped{"中"};
    constexpr Rect narrow{.width = cell_width, .height = 20};

    clipped.paint("中", narrow, cell_width, record);
    check(clipped.matched() == 0 && count == matches.size(), "an invisible partial cluster must not consume a query match");
  }

  const telar::testing::Case case_word_wrapping_borrows_complete_lines{"history_card.word_wrapping_borrows_complete_lines", wordWrappingBorrowsCompleteLines};
  const telar::testing::Case case_graphemes_and_invalid_bytes_keep_their_boundaries{"history_card.graphemes_and_invalid_bytes_keep_their_boundaries", graphemesAndInvalidBytesKeepTheirBoundaries};
  const telar::testing::Case case_strict_and_nonthrowing_scalar_reads_agree{"history_card.strict_and_nonthrowing_scalar_reads_agree", strictAndNonthrowingScalarReadsAgree};
  const telar::testing::Case case_cards_bound_the_remaining_line_count{"history_card.cards_bound_the_remaining_line_count", cardsBoundTheRemainingLineCount};
  const telar::testing::Case case_highlights_continue_across_visible_lines{"history_card.highlights_continue_across_visible_lines", highlightsContinueAcrossVisibleLines};

}
