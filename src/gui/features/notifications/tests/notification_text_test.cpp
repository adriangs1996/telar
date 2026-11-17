#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstddef>
#include <cstring>
#include <string_view>
#include <utility>

import telar.testing;
import telar.gui.foundation.text;
import telar.gui.features.notifications;

namespace {

  using telar::testing::check;
  using namespace telar::gui;

  using namespace telar::gui::features::notifications;

  float measure(std::string_view text) {
    GraphemeCursor cursor{text};
    std::size_t columns = 0;

    while (cursor.next()) {
      ++columns;
    }

    return static_cast<float>(columns);
  }

  void wrappingRetainsWordsAndGraphemes() {
    NotificationText text;
    constexpr float width = 5;

    text.wrap(" \t one two three four \r\n", width, measure);
    check(text.count() == NotificationText::maximum_lines && text.line(0) == "one" && text.line(1) == "two" && text.line(2) == "thre…", "wrapping must prefer word boundaries and truncate only the final line");

    text.wrap("ábcd efg", 2, measure);
    check(text.count() == NotificationText::maximum_lines && text.line(0) == "áb" && text.line(1) == "cd" && text.line(2) == "e…", "combining clusters must never split at line boundaries");
    text.wrap("oversized", 0, measure);
    check(text.count() == 0, "a first grapheme wider than the body must stop wrapping");
    text.wrap(" \t\r\n ", width, measure);
    check(text.count() == 0, "empty and whitespace-only bodies must not reserve rows");
  }

  void paragraphsAndOwnedTailsSurviveCopies() {
    NotificationText text;
    constexpr float width = 10;

    text.wrap("first\r\nsecond\nthird\nfourth", width, measure);
    check(text.count() == NotificationText::maximum_lines && text.line(0) == "first" && text.line(1) == "second" && text.line(2) == "third…", "a hidden following paragraph must be announced even when the final paragraph fits");
    auto moved = std::move(text);

    text = {};
    text.wrap("replacement", width, measure);
    check(moved.line(2) == "third…", "owned ellipsis text must not retain a pointer into its prior object");
    moved.wrap("first\nsecond\nthird", width, measure);
    check(moved.line(2) == "third", "the complete final paragraph must not receive an unnecessary ellipsis");
  }

  const telar::testing::Case case_wrapping_retains_words_and_graphemes{"notification_text.wrapping_retains_words_and_graphemes", wrappingRetainsWordsAndGraphemes};
  const telar::testing::Case case_paragraphs_and_owned_tails_survive_copies{"notification_text.paragraphs_and_owned_tails_survive_copies", paragraphsAndOwnedTailsSurviveCopies};

}
