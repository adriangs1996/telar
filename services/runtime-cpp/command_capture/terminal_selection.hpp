#pragma once

#include "../terminal/selection_formatter.hpp"
#include "../text/utf8.hpp"
#include "cell_layout.hpp"
#include <optional>

namespace telar::runtime {

template <Allocator Memory>
class CommandSelection {
public:
  static constexpr std::size_t maximum_bytes = 64 * 1024;

  explicit CommandSelection(Terminal<Memory> &terminal)
      : terminal_(terminal) {
    const auto position = point(GHOSTTY_POINT_TAG_ACTIVE, cursor());
    checkGhostty(ghostty_terminal_grid_ref_track(terminal.handle(), position, anchor_.output()));
    checkGhostty(ghostty_terminal_grid_ref_track(terminal.handle(), position, right_prompt_.output()));
  }

  bool primary() const {
    GhosttyTerminalScreen screen{};
    checkGhostty(ghostty_terminal_get(terminal_.handle(), GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen));
    return screen == GHOSTTY_TERMINAL_SCREEN_PRIMARY;
  }

  void begin() {
    set(anchor_, GHOSTTY_POINT_TAG_ACTIVE, cursor());
    erased_ = false;
    findRightPrompt();
  }

  void rebase(std::optional<std::string_view> typed) {
    const auto anchor = snapshot(anchor_);
    if (!anchor) {
      return;
    }

    erased_ |= blank(*anchor, 0, columns());
    const auto position = cursor();
    const auto current = reference(GHOSTTY_POINT_TAG_ACTIVE, position);
    auto start = position.x;
    if (typed && !typed->empty() && typed->size() <= position.x && matches(current, *typed)) {
      start -= typed->size();
    }

    if (start == 0 || blank(current, 0, start)) {
      return;
    }

    const bool same_row = current.node == anchor->node && current.y == anchor->y;
    if (!erased_ && (same_row || start == position.x)) {
      return;
    }

    set(anchor_, GHOSTTY_POINT_TAG_ACTIVE, {start, position.y});
    erased_ = false;
    findRightPrompt();
  }

  std::optional<bool> capture(Vector<Byte, Memory> &destination) {
    TELAR_TRACE("history.captureSelection");
    destination.clear();
    const auto anchor = snapshot(anchor_);
    if (!primary() || !anchor || erased_ || blank(*anchor, 0, columns())) {
      return std::nullopt;
    }

    const auto start = coordinates(*anchor);
    auto finish = coordinates(reference(GHOSTTY_POINT_TAG_ACTIVE, cursor()));
    if (before(finish, start)) {
      return std::nullopt;
    }

    const auto maximum_rows = maximum_bytes / columns() + 2;
    if (finish.y - start.y > maximum_rows) {
      finish = {static_cast<std::uint16_t>(columns() - 1), start.y + static_cast<std::uint32_t>(maximum_rows)};
    }

    finish = selectionFinish(start, finish);
    auto selection = ghosttySized<GhosttySelection>();
    selection.start = *anchor;
    selection.end = reference(GHOSTTY_POINT_TAG_SCREEN, finish);
    destination.resize(maximum_bytes + utf8_maximum_width);
    PrefixWriter writer{destination};
    formatTerminalSelection(terminal_, selection, true, GhosttyWriter{.write = PrefixWriter::receive, .userdata = &writer});
    destination.resize(writer.length);
    if (destination.empty()) {
      return std::nullopt;
    }

    const bool truncated = writer.overflow || destination.size() > maximum_bytes;
    const std::string_view text{reinterpret_cast<const char *>(destination.data()), destination.size()};
    destination.resize(utf8Prefix(text, maximum_bytes).size());
    return truncated;
  }

private:
  using TrackedReference = GhosttyHandle<GhosttyTrackedGridRef, ghostty_tracked_grid_ref_free>;
  static constexpr std::size_t utf8_maximum_width = 4;
  static constexpr std::uint64_t hash_basis = 0xcbf29ce484222325;
  static constexpr std::uint64_t hash_prime = 0x100000001b3;

  struct PrefixWriter {
    std::span<Byte> destination;
    std::size_t length = 0;
    bool overflow = false;

    static bool receive(void *context, const Byte *bytes, std::size_t count) noexcept {
      auto &writer = *static_cast<PrefixWriter *>(context);
      const auto copied = std::min(count, writer.destination.size() - writer.length);
      std::copy_n(bytes, copied, writer.destination.data() + writer.length);
      writer.length += copied;
      writer.overflow |= copied != count;
      return true;
    }
  };

  std::uint16_t columns() const noexcept {
    return terminal_.screen.cols;
  }

  GhosttyPointCoordinate cursor() const {
    std::uint16_t column = 0;
    std::uint16_t row = 0;
    checkGhostty(ghostty_terminal_get(terminal_.handle(), GHOSTTY_TERMINAL_DATA_CURSOR_X, &column));
    checkGhostty(ghostty_terminal_get(terminal_.handle(), GHOSTTY_TERMINAL_DATA_CURSOR_Y, &row));
    return {column, row};
  }

  static GhosttyPoint point(GhosttyPointTag tag, GhosttyPointCoordinate coordinate) noexcept {
    return {.tag = tag, .value = {.coordinate = coordinate}};
  }

  GhosttyGridRef reference(GhosttyPointTag tag, GhosttyPointCoordinate coordinate) const {
    auto result = ghosttySized<GhosttyGridRef>();
    checkGhostty(ghostty_terminal_grid_ref(terminal_.handle(), point(tag, coordinate), &result));
    return result;
  }

  static std::optional<GhosttyGridRef> snapshot(const TrackedReference &tracked) {
    auto result = ghosttySized<GhosttyGridRef>();
    const auto status = ghostty_tracked_grid_ref_snapshot(tracked.get(), &result);
    if (status == GHOSTTY_NO_VALUE) {
      return std::nullopt;
    }

    checkGhostty(status);
    return result;
  }

  GhosttyPointCoordinate coordinates(const GhosttyGridRef &reference) const {
    GhosttyPointCoordinate result{};
    checkGhostty(ghostty_terminal_point_from_grid_ref(terminal_.handle(), &reference, GHOSTTY_POINT_TAG_SCREEN, &result));
    return result;
  }

  void set(TrackedReference &tracked, GhosttyPointTag tag, GhosttyPointCoordinate coordinate) {
    checkGhostty(ghostty_tracked_grid_ref_set(tracked.get(), terminal_.handle(), point(tag, coordinate)));
  }

  static bool before(GhosttyPointCoordinate left, GhosttyPointCoordinate right) noexcept {
    return left.y < right.y || (left.y == right.y && left.x < right.x);
  }

  static GhosttyCell cell(GhosttyGridRef reference, std::uint16_t column) {
    reference.x = column;
    GhosttyCell result = 0;
    checkGhostty(ghostty_grid_ref_cell(&reference, &result));
    return result;
  }

  static bool hasText(GhosttyCell cell) noexcept {
    const auto content = cell_layout::content_tag(cell);
    return (content == GHOSTTY_CELL_CONTENT_CODEPOINT || content == GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME) && cell_layout::codepoint(cell) != 0;
  }

  static bool blank(GhosttyGridRef row, std::uint16_t start, std::uint16_t finish) {
    for (auto column = start; column < finish; ++column) {
      const auto value = cell(row, column);
      if (hasText(value) && cell_layout::codepoint(value) != ' ') {
        return false;
      }
    }

    return true;
  }

  static bool matches(GhosttyGridRef cursor, std::string_view typed) {
    const auto start = cursor.x - typed.size();
    for (std::size_t index = 0; index < typed.size(); ++index) {
      const auto value = cell(cursor, start + index);
      const auto codepoint = hasText(value) ? cell_layout::codepoint(value) : ' ';
      if (codepoint != static_cast<unsigned char>(typed[index])) {
        return false;
      }
    }

    return true;
  }

  std::uint64_t hash(GhosttyGridRef start) const {
    auto result = hash_basis;
    for (auto column = start.x; column < columns(); ++column) {
      result = (result ^ cell(start, column)) * hash_prime;
    }

    return result;
  }

  void findRightPrompt() {
    right_prompt_active_ = false;
    auto anchor = *snapshot(anchor_);
    unsigned blank_columns = 0;
    for (auto column = anchor.x; column < columns(); ++column) {
      if (!hasText(cell(anchor, column))) {
        ++blank_columns;
        continue;
      }

      if (blank_columns < 2) {
        blank_columns = 0;
        continue;
      }

      anchor.x = column;
      set(right_prompt_, GHOSTTY_POINT_TAG_SCREEN, coordinates(anchor));
      right_prompt_hash_ = hash(anchor);
      right_prompt_active_ = true;
      return;
    }
  }

  GhosttyPointCoordinate selectionFinish(GhosttyPointCoordinate start, GhosttyPointCoordinate fallback) const {
    const auto right_prompt = right_prompt_active_ ? snapshot(right_prompt_) : std::nullopt;
    if (!right_prompt || right_prompt->x == 0) {
      return fallback;
    }

    auto position = coordinates(*right_prompt);
    if (before(start, position) && before(position, fallback) && hash(*right_prompt) == right_prompt_hash_) {
      --position.x;
      return position;
    }

    return fallback;
  }

  Terminal<Memory> &terminal_;
  TrackedReference anchor_;
  TrackedReference right_prompt_;
  std::uint64_t right_prompt_hash_ = 0;
  bool right_prompt_active_ = false;
  bool erased_ = false;
};

}
