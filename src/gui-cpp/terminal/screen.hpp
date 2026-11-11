#pragma once

#include "core/memory.hpp"
#include "core/terminal_size.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <algorithm>
#include <array>
#include <cstring>
#include <string_view>

namespace telar::gui {

struct CellValue {
  static constexpr std::size_t text_capacity = 16;

  CellStyle style;
  std::array<Byte, text_capacity> text{};
  CellWidth width = CellWidth::single;
  Byte length = 1;

  CellValue() noexcept {
    text[0] = ' ';
  }

  explicit CellValue(const Cell &source) noexcept
      : style(source.style),
        width(source.width),
        length(static_cast<Byte>(source.text.size())) {
    std::ranges::copy(source.text, text.begin());
  }

  [[nodiscard]] std::string_view utf8() const noexcept {
    return textView(std::span{text}.first(length));
  }
};

enum class FrameApplication : std::uint8_t {
  applied,
  stale,
  needs_snapshot,
};

template <Allocator Memory>
class Screen {
public:
  static constexpr std::size_t maximum_cells = TerminalGrid::maximum_cells;

  explicit Screen(Memory &memory)
      : cells_(AllocatorRef<CellValue, Memory>{memory}),
        row_revisions_(AllocatorRef<std::uint64_t, Memory>{memory}),
        row_flags_(AllocatorRef<Byte, Memory>{memory}),
        links_(AllocatorRef<MetadataLink, Memory>{memory}),
        link_runs_(AllocatorRef<MetadataRun, Memory>{memory}),
        uris_(AllocatorRef<Byte, Memory>{memory}) {}

  void detach() noexcept {
    frame_id_ = 0;
  }

  FrameApplication apply(const PaneFrame &frame) {
    frame.validate();

    if (frame.pane_id == pane_id_ && frame.frame_id <= frame_id_) {
      return FrameApplication::stale;
    }

    const auto snapshot = frame.base_frame_id == 0;
    const auto same_grid = columns_ == frame.cols && rows_ == frame.rows;
    if (!snapshot && (frame.pane_id != pane_id_ || frame.base_frame_id != frame_id_ || !same_grid)) {
      return FrameApplication::needs_snapshot;
    }

    for (const auto &span : frame.spans) {
      auto reader = span.reader();
      while (reader.next()) {
      }
    }

    reserve(frame);

    if (snapshot) {
      cells_.resize(static_cast<std::size_t>(frame.cols) * frame.rows);
      row_revisions_.assign(frame.rows, revision_ + 1);
    }

    for (const auto &span : frame.spans) {
      auto reader = span.reader();
      auto position = span.start;
      while (const auto cell = reader.next()) {
        cells_[position] = CellValue{*cell};
        row_revisions_[position / frame.cols] = revision_ + 1;
        ++position;
      }
    }

    if (frame.text_metadata) {
      const auto &metadata = *frame.text_metadata;
      metadata_status_ = metadata.status;
      row_flags_.assign(metadata.row_flags.begin(), metadata.row_flags.end());
      links_.assign(metadata.links.begin(), metadata.links.end());
      link_runs_.assign(metadata.runs.begin(), metadata.runs.end());
      uris_.assign(metadata.uris.begin(), metadata.uris.end());
    }

    pane_id_ = frame.pane_id;
    frame_id_ = frame.frame_id;
    columns_ = frame.cols;
    rows_ = frame.rows;
    cursor_ = frame.cursor;
    mouse_ = frame.mouse;
    modes_ = frame.input_modes;
    scroll_ = frame.scroll;
    cells_offset_ = frame.scroll.offset;
    pointer_shape_ = frame.pointer_shape;
    ++revision_;

    return FrameApplication::applied;
  }

  [[nodiscard]] std::span<const CellValue> row(std::size_t index) const noexcept {
    return index < rows_ ? std::span<const CellValue>{cells_}.subspan(index * columns_, columns_) : std::span<const CellValue>{};
  }

  [[nodiscard]] std::span<const CellValue> cells() const noexcept {
    return cells_;
  }

  [[nodiscard]] std::uint64_t rowRevision(std::size_t index) const noexcept {
    return index < row_revisions_.size() ? row_revisions_[index] : 0;
  }

  [[nodiscard]] Byte rowFlags(std::size_t index) const noexcept {
    return index < row_flags_.size() ? row_flags_[index] : 0;
  }

  [[nodiscard]] std::span<const Byte> rowFlags() const noexcept {
    return row_flags_;
  }

  [[nodiscard]] MetadataStatus metadataStatus() const noexcept {
    return metadata_status_;
  }

  [[nodiscard]] std::span<const MetadataRun> linkRuns() const noexcept {
    return link_runs_;
  }

  [[nodiscard]] std::string_view linkAt(std::uint32_t cell) const noexcept {
    const auto *run = linkRunAt(cell);
    if (run == nullptr) {
      return {};
    }

    const auto &link = links_[run->link_index];

    return textView(std::span{uris_}.subspan(link.offset, link.len));
  }

  [[nodiscard]] const MetadataRun *linkRunAt(std::uint32_t cell) const noexcept {
    const auto found = std::upper_bound(link_runs_.begin(), link_runs_.end(), cell, [](auto position, const MetadataRun &run) {
      return position < run.start;
    });
    if (found == link_runs_.begin()) {
      return nullptr;
    }

    const auto &run = *std::prev(found);
    if (cell - run.start >= run.len) {
      return nullptr;
    }

    return &run;
  }

  [[nodiscard]] std::uint16_t columns() const noexcept {
    return columns_;
  }

  [[nodiscard]] std::uint16_t rows() const noexcept {
    return rows_;
  }

  [[nodiscard]] std::uint64_t paneId() const noexcept {
    return pane_id_;
  }

  [[nodiscard]] std::uint64_t frameId() const noexcept {
    return frame_id_;
  }

  [[nodiscard]] std::uint64_t revision() const noexcept {
    return revision_;
  }

  [[nodiscard]] const Cursor &cursor() const noexcept {
    return cursor_;
  }

  [[nodiscard]] const Mouse &mouse() const noexcept {
    return mouse_;
  }

  [[nodiscard]] const InputModes &modes() const noexcept {
    return modes_;
  }

  [[nodiscard]] const Scroll &scroll() const noexcept {
    return scroll_;
  }

  // A screen put together from rows a view draws, each with its flags; `runs` start at cells
  // counted from the first row's first. It shows its rows from row 0 of a scrollback of as
  // many, with no cursor.
  void compose(std::uint16_t columns, std::span<const std::span<const CellValue>> rows, std::span<const Byte> flags, const TextMetadata &metadata) {
    columns_ = columns;
    rows_ = static_cast<std::uint16_t>(rows.size());
    cells_.resize(static_cast<std::size_t>(columns_) * rows_);
    for (std::size_t row = 0; row < rows.size(); ++row) {
      const auto cells = rows[row].first(std::min<std::size_t>(columns_, rows[row].size()));
      std::ranges::copy(cells, cells_.begin() + static_cast<std::ptrdiff_t>(row * columns_));
      std::fill(cells_.begin() + static_cast<std::ptrdiff_t>((row * columns_) + cells.size()), cells_.begin() + static_cast<std::ptrdiff_t>((row + 1) * columns_), CellValue{});
    }
    row_revisions_.assign(rows_, ++revision_);
    row_flags_.assign(flags.begin(), flags.end());
    row_flags_.resize(rows_, 0);
    metadata_status_ = metadata.status;
    links_.assign(metadata.links.begin(), metadata.links.end());
    link_runs_.assign(metadata.runs.begin(), metadata.runs.end());
    uris_.assign(metadata.uris.begin(), metadata.uris.end());
    cursor_ = {};
    scroll_ = {.total_rows = rows_, .offset = 0};
    cells_offset_ = 0;
  }

  // The row, from the top of the scrollback, the cells start on: the offset of the frame they
  // came in, which `setViewport` leaves until the runtime sends the view it asked for.
  [[nodiscard]] std::uint32_t cellsOffset() const noexcept {
    return cells_offset_;
  }

  void setViewport(std::uint32_t offset) noexcept {
    const auto maximum = scroll_.total_rows - std::min<std::uint32_t>(scroll_.total_rows, rows_);
    scroll_.offset = std::min(offset, maximum);
  }

  [[nodiscard]] PointerShape pointerShape() const noexcept {
    return pointer_shape_;
  }

private:
  Cursor cursor_;
  Mouse mouse_;
  InputModes modes_;
  Scroll scroll_;
  std::uint32_t cells_offset_ = 0;
  PointerShape pointer_shape_{};
  MetadataStatus metadata_status_ = MetadataStatus::complete;

  void reserve(const PaneFrame &frame) {
    cells_.reserve(static_cast<std::size_t>(frame.cols) * frame.rows);
    row_revisions_.reserve(frame.rows);

    if (frame.text_metadata) {
      row_flags_.reserve(frame.text_metadata->row_flags.size());
      links_.reserve(frame.text_metadata->links.size());
      link_runs_.reserve(frame.text_metadata->runs.size());
      uris_.reserve(frame.text_metadata->uris.size());
    }
  }

  Vector<CellValue, Memory> cells_;
  Vector<std::uint64_t, Memory> row_revisions_;
  Vector<Byte, Memory> row_flags_;
  Vector<MetadataLink, Memory> links_;
  Vector<MetadataRun, Memory> link_runs_;
  Vector<Byte, Memory> uris_;
  std::uint64_t pane_id_ = 0;
  std::uint64_t frame_id_ = 0;
  std::uint64_t revision_ = 0;
  std::uint16_t columns_ = 0;
  std::uint16_t rows_ = 0;
};

}
