#pragma once

#include "selection_formatter.hpp"
#include "telar_client/serializers/telar_protocol.hpp"

namespace telar::runtime {

template <Allocator Memory>
class TextReader {
public:
  explicit TextReader(Memory &memory, Terminal<Memory> &terminal, std::size_t capacity)
      : terminal_(terminal),
        bytes_(AllocatorRef<Byte, Memory>{memory}) {
    bytes_.resize(capacity);
  }

  void read(PaneTextSource source, std::uint16_t wanted_rows) {
    const auto tag = source == PaneTextSource::screen ? GHOSTTY_POINT_TAG_ACTIVE : GHOSTTY_POINT_TAG_SCREEN;
    auto rows = source == PaneTextSource::screen ? terminal_.screen.rows : totalRows();
    const auto blank_limit = static_cast<std::size_t>(wanted_rows) + terminal_.screen.rows;
    std::size_t inspected = 0;

    while (rows != 0 && inspected++ < blank_limit && rowIsBlank(tag, rows - 1)) {
      --rows;
    }

    if (rows == 0) {
      return;
    }

    const auto count = std::min<std::uint32_t>(wanted_rows, rows);
    auto selection = ghosttySized<GhosttySelection>();
    selection.start = reference(tag, {0, rows - count});
    selection.end = reference(tag, {static_cast<std::uint16_t>(terminal_.screen.cols - 1), rows - 1});
    format(selection, false);
  }

  void copy(const CopySelection &request) {
    const auto columns = terminal_.screen.cols;
    const auto bottom = totalRows() - 1;
    GhosttyPointCoordinate start{
        .x = request.linewise ? std::uint16_t{0} : std::min<std::uint16_t>(request.start_x, columns - 1),
        .y = request.linewise ? std::min(request.start_y, request.end_y) : request.start_y,
    };
    GhosttyPointCoordinate end{
        .x = request.linewise ? static_cast<std::uint16_t>(columns - 1) : std::min<std::uint16_t>(request.end_x, columns - 1),
        .y = request.linewise ? std::max(request.start_y, request.end_y) : request.end_y,
    };

    for (auto *point : {&start, &end}) {
      if (point->y > bottom) {
        *point = {static_cast<std::uint16_t>(columns - 1), bottom};
      }
    }

    auto selection = ghosttySized<GhosttySelection>();
    selection.start = reference(GHOSTTY_POINT_TAG_SCREEN, start);
    selection.end = reference(GHOSTTY_POINT_TAG_SCREEN, end);
    format(selection, true);
  }

  std::span<const Byte> bytes() const noexcept {
    return std::span<const Byte>{bytes_}.first(length_);
  }

  std::string_view text() const noexcept {
    return {reinterpret_cast<const char *>(bytes_.data()), length_};
  }

  bool truncated() const noexcept {
    return wrapped_;
  }

private:
  std::uint32_t totalRows() const {
    std::size_t count = 0;
    checkGhostty(ghostty_terminal_get(terminal_.handle(), GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &count));
    return static_cast<std::uint32_t>(std::min<std::size_t>(count, UINT32_MAX));
  }

  GhosttyGridRef reference(GhosttyPointTag tag, GhosttyPointCoordinate coordinate) const {
    auto result = ghosttySized<GhosttyGridRef>();
    checkGhostty(ghostty_terminal_grid_ref(terminal_.handle(), GhosttyPoint{.tag = tag, .value = {.coordinate = coordinate}}, &result));
    return result;
  }

  bool rowIsBlank(GhosttyPointTag tag, std::uint32_t row) const {
    auto cell_ref = reference(tag, {0, row});
    for (std::uint16_t column = 0; column < terminal_.screen.cols; ++column) {
      cell_ref.x = column;
      GhosttyCell raw = 0;
      checkGhostty(ghostty_grid_ref_cell(&cell_ref, &raw));
      const auto content = cell_layout::content_tag(raw);
      const auto codepoint = cell_layout::codepoint(raw);
      const bool text = content == GHOSTTY_CELL_CONTENT_CODEPOINT || content == GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME;
      if (text && codepoint != 0 && codepoint != ' ') {
        return false;
      }
    }

    return true;
  }

  void format(const GhosttySelection &selection, bool unwrap) {
    formatTerminalSelection(terminal_, selection, unwrap, GhosttyWriter{.write = receive, .userdata = this});

    if (!wrapped_) {
      length_ = position_;
      return;
    }

    std::rotate(bytes_.begin(), bytes_.begin() + position_, bytes_.end());
    const auto newline = std::find(bytes_.begin(), bytes_.end(), '\n');
    std::size_t start = newline == bytes_.end() ? 0 : static_cast<std::size_t>(newline - bytes_.begin() + 1);
    if (newline == bytes_.end()) {
      constexpr Byte continuation_mask = 0xc0;
      constexpr Byte continuation_bits = 0x80;
      while (start < bytes_.size() && (bytes_[start] & continuation_mask) == continuation_bits) {
        ++start;
      }
    }

    std::move(bytes_.begin() + start, bytes_.end(), bytes_.begin());
    length_ = bytes_.size() - start;
  }

  static bool receive(void *context, const Byte *bytes, std::size_t count) noexcept {
    auto &self = *static_cast<TextReader *>(context);
    while (count != 0) {
      if (self.position_ == self.bytes_.size()) {
        self.position_ = 0;
        self.wrapped_ = true;
      }

      const auto copied = std::min(count, self.bytes_.size() - self.position_);
      std::copy_n(bytes, copied, self.bytes_.begin() + self.position_);
      bytes += copied;
      count -= copied;
      self.position_ += copied;
    }

    return true;
  }

  Terminal<Memory> &terminal_;
  Vector<Byte, Memory> bytes_;
  std::size_t position_ = 0;
  std::size_t length_ = 0;
  bool wrapped_ = false;
};

}
