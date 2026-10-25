#pragma once

#include "cell_layout.hpp"
#include "ghostty_handle.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <chrono>

namespace telar::runtime {

class TextSearch {
public:
  explicit TextSearch(const SearchPane &request, std::uint64_t revision)
      : request_id(request.request_id),
        pane_id(request.pane_id),
        revision_(revision),
        deadline_(Clock::now() + deadline_budget) {
    if (request.needle.size() > needle_.size()) {
      throw EncodingError{"Search needle exceeds the wire limit"};
    }
    validateUtf8(request.needle);
    auto text = request.needle;
    while (!text.empty()) {
      const auto first = static_cast<Byte>(text.front());
      const std::size_t length = first < 0x80 ? 1 : first < 0xe0 ? 2
                                                : first < 0xf0   ? 3
                                                                 : 4;
      std::uint32_t codepoint = length == 1 ? first : first & (0x7f >> length);
      for (std::size_t index = 1; index < length; ++index) {
        codepoint = (codepoint << 6) | (static_cast<Byte>(text[index]) & 0x3f);
      }

      needle_[needle_length_++] = codepoint;
      fold_ascii_ &= codepoint < 'A' || codepoint > 'Z';
      text.remove_prefix(length);
    }

    for (std::size_t index = 0; index < needle_length_; ++index) {
      needle_[index] = normalize(needle_[index]);
    }

    std::size_t matched = 0;
    for (std::size_t index = 1; index < needle_length_; ++index) {
      while (matched != 0 && needle_[index] != needle_[matched]) {
        matched = prefix_[matched - 1];
      }

      if (needle_[index] == needle_[matched]) {
        ++matched;
      }
      prefix_[index] = matched;
    }
  }

  bool advance(GhosttyTerminal terminal, std::uint64_t revision) {
    if (revision != revision_) {
      throw EncodingError{"Pane changed during search"};
    }

    if (needle_length_ == 0) {
      return true;
    }

    if (!started_) {
      checkGhostty(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &next_row_));
      checkGhostty(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLS, &columns_));
      first_row_ = next_row_ > maximum_rows ? next_row_ - maximum_rows : 0;
      truncated_ = first_row_ != 0;
      started_ = true;
    }

    if (Clock::now() >= deadline_) {
      truncated_ = true;
      return true;
    }

    for (std::size_t turn = 0; turn < rows_per_turn && next_row_ > first_row_; ++turn) {
      if (!searchRow(terminal, --next_row_)) {
        return true;
      }
    }

    return next_row_ == first_row_;
  }

  PaneMatches result() {
    std::reverse(matches_.begin(), matches_.begin() + count_);
    return PaneMatches{.request_id = request_id,
                       .pane_id = pane_id,
                       .truncated = truncated_,
                       .matches = std::span<const PaneMatch>{matches_}.first(count_)};
  }

  std::uint64_t request_id;
  std::uint64_t pane_id;

private:
  std::uint32_t normalize(std::uint32_t codepoint) const noexcept {
    return fold_ascii_ && codepoint >= 'A' && codepoint <= 'Z' ? codepoint + ('a' - 'A') : codepoint;
  }

  bool searchRow(GhosttyTerminal terminal, std::uint32_t row) {
    auto reference = ghosttySized<GhosttyGridRef>();
    checkGhostty(ghostty_terminal_grid_ref(terminal, GhosttyPoint{.tag = GHOSTTY_POINT_TAG_SCREEN, .value = {.coordinate = {0, row}}}, &reference));
    std::array<std::uint16_t, maximum_columns> positions;
    std::array<PaneMatch, maximum_columns> found;
    std::size_t found_count = 0;
    std::size_t row_length = 0;
    std::size_t matched = 0;

    for (std::uint16_t column = 0; column < columns_; ++column) {
      if (row_length == maximum_columns) {
        truncated_ = true;
        break;
      }

      reference.x = column;
      GhosttyCell cell = 0;
      checkGhostty(ghostty_grid_ref_cell(&reference, &cell));
      const auto width = cell_layout::wide(cell);
      if (width == GHOSTTY_CELL_WIDE_SPACER_HEAD || width == GHOSTTY_CELL_WIDE_SPACER_TAIL) {
        continue;
      }

      positions[row_length++] = column;
      const auto content = cell_layout::content_tag(cell);
      auto codepoint = content == GHOSTTY_CELL_CONTENT_CODEPOINT || content == GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME ? cell_layout::codepoint(cell) : 0;
      codepoint = normalize(codepoint == 0 ? ' ' : codepoint);
      while (matched != 0 && codepoint != needle_[matched]) {
        matched = prefix_[matched - 1];
      }

      if (codepoint == needle_[matched]) {
        ++matched;
      }

      if (matched == needle_length_) {
        const auto start = positions[row_length - needle_length_];
        found[found_count++] = PaneMatch{.x = start,
                                         .y = row,
                                         .len = static_cast<std::uint16_t>(column - start + 1)};
        matched = 0;
      }
    }

    while (found_count != 0) {
      if (count_ == matches_.size()) {
        truncated_ = true;
        return false;
      }
      matches_[count_++] = found[--found_count];
    }

    return true;
  }

  using Clock = std::chrono::steady_clock;
  static constexpr std::size_t maximum_rows = 50000;
  static constexpr std::size_t maximum_columns = 512;
  static constexpr std::size_t rows_per_turn = 32;
  static constexpr auto deadline_budget = std::chrono::milliseconds{(maximum_rows + rows_per_turn - 1) / rows_per_turn};
  std::array<std::uint32_t, 128> needle_{};
  std::array<std::size_t, 128> prefix_{};
  std::array<PaneMatch, 256> matches_{};
  std::uint64_t revision_;
  Clock::time_point deadline_;
  std::size_t needle_length_ = 0;
  std::size_t next_row_ = 0;
  std::size_t first_row_ = 0;
  std::size_t count_ = 0;
  std::uint16_t columns_ = 0;
  bool fold_ascii_ = true;
  bool truncated_ = false;
  bool started_ = false;
};

}
