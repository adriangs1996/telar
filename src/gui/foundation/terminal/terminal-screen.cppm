module;
#include "telar_base/diagnostics/config.hpp"

export module telar.gui.foundation.terminal:screen;

import std;

import telar.wire.vocabulary;
import telar.gui.foundation.core;
import telar.base.ds;

export namespace telar::gui::inline foundation::inline terminal {

  // Compared for every cell a selection covers.
  struct [[tbc::hot_path]] CellPosition {
    std::uint16_t x = 0;
    std::uint32_t y = 0;

    [[nodiscard]] inline auto operator<=>(const CellPosition& other) const noexcept {
      return std::tie(y, x) <=> std::tie(other.y, other.x);
    }

    bool operator==(const CellPosition&) const = default;
  };

  // Built and read for every cell of a frame.
  struct [[tbc::hot_path]] CellValue {
    static constexpr std::size_t text_capacity = 16;

    CellStyle style;
    ds::Array<Byte, text_capacity> text{};
    CellWidth width = CellWidth::single;
    Byte length = 1;

    inline CellValue() noexcept {
      text.atMut(0) = ' ';
    }

    inline explicit CellValue(const Cell& source) noexcept
        : style(source.style),
          width(source.width),
          length(static_cast<Byte>(source.text.size())) {
      std::ranges::copy(source.text, text.viewMut().begin());
    }

    [[nodiscard]] inline std::string_view utf8() const noexcept {
      return textView(std::span{text}.first(length));
    }
  };

  // The cells of a grid that is not a terminal's screen: an editor's window, which has a size
  // of its own.
  struct GridExtent {
    std::uint16_t columns = 0;
    std::uint16_t rows = 0;
  };

  // Rows `top` up to `bottom` of columns `left` up to `right`, moved `rows` rows up, or down
  // when negative: what scrolled out is left as it was, for the cells sent after it to replace.
  struct RowMove {
    std::uint16_t top = 0;
    std::uint16_t bottom = 0;
    std::uint16_t left = 0;
    std::uint16_t right = 0;
    std::int32_t rows = 0;
  };

  enum class FrameApplication : std::uint8_t {
    applied,
    stale,
    needs_snapshot,
  };

  template <Allocator Memory>
  class [[tbc::generic]] Screen {
  public:
    static constexpr std::size_t maximum_cells = TerminalGrid::maximum_cells;

    explicit Screen(Memory& memory)
        : cells_(memory),
          row_revisions_(memory),
          row_flags_(memory),
          links_(memory),
          link_runs_(memory),
          uris_(memory),
          staged_(memory) {}

    void detach() noexcept {
      frame_id_ = 0;
    }

    FrameApplication apply(const PaneFrame& frame) {
      frame.validate();
      // validate() rejects a frame without columns, which the spans' rows divide by.
      TELAR_ASSERT(frame.cols != 0);

      if (frame.pane_id == pane_id_ && frame.frame_id <= frame_id_) {
        return FrameApplication::stale;
      }

      const auto snapshot = frame.base_frame_id == 0;
      const auto same_grid = columns_ == frame.cols && rows_ == frame.rows;
      if (!snapshot && (frame.pane_id != pane_id_ || frame.base_frame_id != frame_id_ || !same_grid)) {
        return FrameApplication::needs_snapshot;
      }

      // Every span is decoded before anything changes, so a frame that fails to decode leaves the
      // screen as it was.
      stage(frame.spans);
      reserve(frame);

      if (snapshot) {
        cells_.resize(static_cast<std::size_t>(frame.cols) * frame.rows);
        row_revisions_.clear();
        row_revisions_.resize(frame.rows, revision_ + 1);
      }

      commit(frame.cols, frame.spans);

      if (frame.text_metadata) {
        const auto& metadata = *frame.text_metadata;

        metadata_status_ = metadata.status;
        row_flags_.clear();
        row_flags_.extend({metadata.row_flags.begin(), metadata.row_flags.end()});
        links_.clear();
        links_.extend({metadata.links.begin(), metadata.links.end()});
        link_runs_.clear();
        link_runs_.extend({metadata.runs.begin(), metadata.runs.end()});
        uris_.clear();
        uris_.extend({metadata.uris.begin(), metadata.uris.end()});
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

    // Changes the cells of a grid an editor draws. `whole` gives it its size and blanks it
    // first; otherwise the spans change the cells it has. False, with the grid as it was, for
    // cells that do not fit the grid: a grid of another size that was not sent whole, or a span
    // past its end.
    bool draw(GridExtent extent, bool whole, std::span<const FrameSpan> spans) {
      const auto count = static_cast<std::size_t>(extent.columns) * extent.rows;
      if (count == 0 || count > maximum_cells || (!whole && (extent.columns != columns_ || extent.rows != rows_))) {
        return false;
      }

      for (const auto& span : spans) {
        if (span.count == 0 || span.start >= count || span.count > count - span.start) {
          return false;
        }
      }

      stage(spans);
      if (whole) {
        columns_ = extent.columns;
        rows_ = extent.rows;
        cells_.clear();
        cells_.resize(count);
        row_revisions_.clear();
        row_revisions_.resize(rows_, revision_ + 1);
        scroll_ = {.total_rows = rows_, .offset = 0};
      }

      commit(columns_, spans);
      ++revision_;
      return true;
    }

    // Moves rows the grid has, as a scroll the editor made does. False for a move outside it.
    bool moveRows(const RowMove& move) {
      if (move.top >= move.bottom || move.bottom > rows_ || move.left >= move.right || move.right > columns_ || move.rows == 0 || std::abs(move.rows) >= move.bottom - move.top) {
        return false;
      }

      const bool upward = move.rows > 0;
      const auto width = static_cast<std::size_t>(move.right - move.left);
      const int step = upward ? 1 : -1;
      const int last = upward ? move.bottom - move.rows : move.top - move.rows - 1;

      // From the end the rows leave, so a row is read before another is written over it.
      for (int row = upward ? move.top : move.bottom - 1; row != last; row += step) {
        const auto source = (static_cast<std::size_t>(row + move.rows) * columns_) + move.left;
        const auto target = (static_cast<std::size_t>(row) * columns_) + move.left;

        std::copy_n(cells_.data() + source, width, cells_.dataMut() + target);
        row_revisions_.atMut(static_cast<std::size_t>(row)) = revision_ + 1;
      }

      ++revision_;
      return true;
    }

    // Where the cursor is drawn on a grid an editor draws, or that it is not on it.
    void placeCursor(const Cursor& cursor) noexcept {
      if (cursor_.visible != cursor.visible || cursor_.x != cursor.x || cursor_.y != cursor.y || cursor_.shape != cursor.shape || cursor_.blink != cursor.blink) {
        cursor_ = cursor;
        ++revision_;
      }
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
      const auto* run = linkRunAt(cell);
      if (run == nullptr) {
        return {};
      }

      const auto& link = links_[run->link_index];

      return textView(std::span{uris_}.subspan(link.offset, link.len));
    }

    [[nodiscard]] const MetadataRun* linkRunAt(std::uint32_t cell) const noexcept {
      const auto found = std::upper_bound(link_runs_.begin(), link_runs_.end(), cell, [](auto position, const MetadataRun& run) {
        return position < run.start;
      });
      if (found == link_runs_.begin()) {
        return nullptr;
      }

      const auto& run = *std::prev(found);
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

    [[nodiscard]] const Cursor& cursor() const noexcept {
      return cursor_;
    }

    [[nodiscard]] const Mouse& mouse() const noexcept {
      return mouse_;
    }

    [[nodiscard]] const InputModes& modes() const noexcept {
      return modes_;
    }

    [[nodiscard]] const Scroll& scroll() const noexcept {
      return scroll_;
    }

    // A screen put together from rows a view draws, each with its flags; `runs` start at cells
    // counted from the first row's first. It shows its rows from row 0 of a scrollback of as
    // many, with no cursor.
    void compose(std::uint16_t columns, std::span<const std::span<const CellValue>> rows, std::span<const Byte> flags, const TextMetadata& metadata) {
      columns_ = columns;
      rows_ = static_cast<std::uint16_t>(rows.size());
      cells_.resize(static_cast<std::size_t>(columns_) * rows_);
      for (std::size_t row = 0; row < rows.size(); ++row) {
        const auto cells = rows[row].first(std::min<std::size_t>(columns_, rows[row].size()));

        std::ranges::copy(cells, cells_.viewMut().begin() + static_cast<std::ptrdiff_t>(row * columns_));
        std::fill(cells_.dataMut() + static_cast<std::ptrdiff_t>((row * columns_) + cells.size()), cells_.dataMut() + static_cast<std::ptrdiff_t>((row + 1) * columns_), CellValue{});
      }

      row_revisions_.clear();
      row_revisions_.resize(rows_, ++revision_);
      row_flags_.clear();
      row_flags_.extend({flags.begin(), flags.end()});
      row_flags_.resize(rows_, 0);
      metadata_status_ = metadata.status;
      links_.clear();
      links_.extend({metadata.links.begin(), metadata.links.end()});
      link_runs_.clear();
      link_runs_.extend({metadata.runs.begin(), metadata.runs.end()});
      uris_.clear();
      uris_.extend({metadata.uris.begin(), metadata.uris.end()});
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

    // Decodes the cells of `spans`, in order, before any of them replaces a cell.
    void stage(std::span<const FrameSpan> spans) {
      std::size_t changed = 0;

      for (const auto& span : spans) {
        changed += span.count;
      }

      staged_.clear();
      staged_.reserve(changed);
      for (const auto& span : spans) {
        auto reader = span.reader();

        while (const auto cell = reader.next()) {
          staged_.emplace(*cell);
        }
      }
    }

    // Writes the staged cells where their spans put them, and marks the rows they change.
    void commit(std::uint16_t columns, std::span<const FrameSpan> spans) {
      const auto* staged = staged_.data();

      for (const auto& span : spans) {
        std::copy_n(staged, span.count, cells_.dataMut() + span.start);
        staged += span.count;
        const auto last = (span.start + span.count - 1) / columns;

        std::fill(row_revisions_.dataMut() + (span.start / columns), row_revisions_.dataMut() + last + 1, revision_ + 1);
      }
    }

    void reserve(const PaneFrame& frame) {
      cells_.reserve(static_cast<std::size_t>(frame.cols) * frame.rows);
      row_revisions_.reserve(frame.rows);

      if (frame.text_metadata) {
        row_flags_.reserve(frame.text_metadata->row_flags.size());
        links_.reserve(frame.text_metadata->links.size());
        link_runs_.reserve(frame.text_metadata->runs.size());
        uris_.reserve(frame.text_metadata->uris.size());
      }
    }

    ds::Vec<CellValue, Memory> cells_;
    ds::Vec<std::uint64_t, Memory> row_revisions_;
    ds::Vec<Byte, Memory> row_flags_;
    ds::Vec<MetadataLink, Memory> links_;
    ds::Vec<MetadataRun, Memory> link_runs_;
    ds::Vec<Byte, Memory> uris_;
    // The cells of the frame being applied, decoded once; kept between frames for its capacity.
    ds::Vec<CellValue, Memory> staged_;
    std::uint64_t pane_id_ = 0;
    std::uint64_t frame_id_ = 0;
    std::uint64_t revision_ = 0;
    std::uint16_t columns_ = 0;
    std::uint16_t rows_ = 0;
  };
}
