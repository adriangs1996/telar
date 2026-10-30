#pragma once

#include "../diagnostics/runtime_counters.hpp"
#include "../diagnostics/trace.hpp"

#include "screen.hpp"
#include <tuple>

namespace telar::runtime {

template <Allocator Memory>
class FrameSync {
public:
  explicit FrameSync(Memory &memory, std::uint64_t pane_id)
      : pane_id_(pane_id),
        baseline_(AllocatorRef<ScreenCell, Memory>{memory}),
        cell_bytes_(AllocatorRef<Byte, Memory>{memory}),
        payload_(AllocatorRef<Byte, Memory>{memory}),
        spans_(AllocatorRef<FrameSpan, Memory>{memory}),
        metadata_bytes_(AllocatorRef<Byte, Memory>{memory}),
        previous_metadata_(AllocatorRef<Byte, Memory>{memory}) {
    spans_.reserve(maximum_spans);
    metadata_bytes_.resize(maximum_metadata_bytes);
    previous_metadata_.reserve(maximum_metadata_bytes);
  }

  bool acknowledge(std::uint64_t frame_id) noexcept {
    TELAR_DIAGNOSTIC(diagnostics::TimedScope timing{counters_ == nullptr ? nullptr : &counters_->ack});
    if (frame_id == 0 || frame_id != outstanding_id_) {
      return false;
    }

    acknowledged_id_ = frame_id;
    outstanding_id_ = 0;
    return true;
  }

  void requestSnapshot() noexcept {
    snapshot_pending_ = true;
  }

  bool needsSnapshot(const Screen<Memory> &screen) const noexcept {
    return snapshot_pending_ || screen.cols != previous_header_.cols || screen.rows != previous_header_.rows;
  }

  bool waitingForAck() const noexcept {
    return outstanding_id_ != 0;
  }

  bool waitingForAck(const Screen<Memory> &screen) const noexcept {
    return waitingForAck() && screen.cols == previous_header_.cols && screen.rows == previous_header_.rows;
  }

  std::uint64_t observedRevision() const noexcept {
    return observed_revision_;
  }

  std::span<const Byte> prepare(const Screen<Memory> &screen) {
    TELAR_TRACE("frame_sync.prepare");
    TELAR_DIAGNOSTIC(diagnostics::TimedScope timing{counters_ == nullptr ? nullptr : &counters_->encode});
    if (screen.cols != previous_header_.cols || screen.rows != previous_header_.rows) {
      outstanding_id_ = 0;
      snapshot_pending_ = true;
      baseline_.resize(screen.cells.size());
      cell_bytes_.resize(screen.cells.size() * maximum_cell_bytes);
      payload_.resize(std::min(max_payload_size, screen.cells.size() * maximum_cell_bytes + maximum_metadata_bytes));
    }

    if (waitingForAck() || (!snapshot_pending_ && observed_revision_ == screen.revision)) {
      return {};
    }

    FrameBody header = frameHeader(screen);
    bool full = snapshot_pending_ || acknowledged_id_ == 0;
    bool metadata_changed = false;
    std::size_t metadata_size = previous_metadata_.size();
    if (full || screen.metadata_revision != metadata_revision_) {
      auto output = std::span<Byte>{metadata_bytes_};
      ValueCodec<TextMetadata>::encode(screen.metadata.view(screen.row_flags), output);
      metadata_size = metadata_bytes_.size() - output.size();
      metadata_changed = metadata_size != previous_metadata_.size() || !std::equal(previous_metadata_.begin(), previous_metadata_.end(), metadata_bytes_.begin());
    }
    spans_.clear();
    auto remaining = std::span<Byte>{cell_bytes_};

    if (full) {
      appendSpan(screen.cells, 0, remaining);
    } else {
      appendDamage(screen, remaining);
      if (spans_.empty() && !metadata_changed && sameHeader(header, previous_header_)) {
        TELAR_DIAGNOSTIC(if (counters_ != nullptr) { diagnostics::accumulate(counters_->noop_frames); });
        observed_revision_ = screen.revision;
        metadata_revision_ = screen.metadata_revision;
        return {};
      }
    }

    header.frame_id = next_frame_id_;
    header.base_frame_id = full ? 0 : acknowledged_id_;
    if (full || metadata_changed) {
      header.text_metadata = screen.metadata.view(screen.row_flags);
    }
    header.spans = spans_;
    if (FrameSerializer::encodedSize(header) + 1 > payload_.size()) {
      spans_.clear();
      remaining = cell_bytes_;
      appendSpan(screen.cells, 0, remaining);
      header.base_frame_id = 0;
      header.text_metadata = screen.metadata.view(screen.row_flags);
      header.spans = spans_;
    }

    auto output = std::span<Byte>{payload_};
    u8::encode(static_cast<Byte>(ServerTag::pane_frame), output);
    FrameSerializer::encodeBody(header, output);
    const auto size = payload_.size() - output.size();
    TELAR_DIAGNOSTIC(recordFrame(size, header.base_frame_id == 0));

    for (const auto &span : spans_) {
      std::copy_n(screen.cells.begin() + span.start, span.count, baseline_.begin() + span.start);
    }

    if (metadata_changed) {
      previous_metadata_.assign(metadata_bytes_.begin(), metadata_bytes_.begin() + metadata_size);
    }

    metadata_revision_ = screen.metadata_revision;
    previous_header_ = header;
    previous_header_.spans = {};
    previous_header_.text_metadata.reset();
    observed_revision_ = screen.revision;
    outstanding_id_ = next_frame_id_++;
    snapshot_pending_ = false;
    return std::span<const Byte>{payload_}.first(size);
  }

#if TELAR_DIAGNOSTICS
  void setCounters(diagnostics::FrameCounters &counters) noexcept {
    counters_ = &counters;
  }
#endif

private:
  FrameBody frameHeader(const Screen<Memory> &screen) const noexcept {
    FrameBody header{};
    header.pane_id = pane_id_;
    header.cols = screen.cols;
    header.rows = screen.rows;
    header.cursor = screen.cursor;
    header.mouse = screen.mouse;
    header.input_modes = screen.input_modes;
    header.pointer_shape = screen.pointer_shape;
    header.scroll = screen.scroll;
    return header;
  }

  static bool sameHeader(const FrameBody &left, const FrameBody &right) noexcept {
    const auto fields = [](const FrameBody &frame) {
      return std::tie(frame.cursor.visible, frame.cursor.x, frame.cursor.y, frame.cursor.shape, frame.cursor.blink,
                      frame.mouse.tracking, frame.mouse.sgr, frame.mouse.pixels,
                      frame.input_modes.cursor_keys, frame.input_modes.keypad_keys, frame.input_modes.bracketed_paste,
                      frame.input_modes.paste_events, frame.input_modes.focus_events, frame.input_modes.alternate_scroll, frame.input_modes.alternate_screen,
                      frame.input_modes.kitty_keyboard_flags, frame.input_modes.modify_other_keys_2,
                      frame.pointer_shape, frame.scroll.total_rows, frame.scroll.offset);
    };

    return fields(left) == fields(right);
  }

  void appendDamage(const Screen<Memory> &screen, std::span<Byte> &remaining) {
    for (std::size_t row = 0; row < screen.rows; ++row) {
      if (screen.row_revisions[row] <= observed_revision_) {
        continue;
      }

      const auto row_start = row * screen.cols;
      std::size_t first = row_start;
      std::size_t end = row_start + screen.cols;

      while (first < end && screen.cells[first] == baseline_[first]) {
        ++first;
      }

      while (end > first && screen.cells[end - 1] == baseline_[end - 1]) {
        --end;
      }

      TELAR_DIAGNOSTIC(if (counters_ != nullptr) {
        diagnostics::accumulate(counters_->damaged_rows);
        diagnostics::accumulate(counters_->diff_scanned_cells, first - row_start + row_start + screen.cols - end + (first < end ? 2 : 0));
      });

      if (first == end) {
        continue;
      }

      if (spans_.size() == maximum_spans) {
        spans_.clear();
        remaining = cell_bytes_;
        appendSpan(screen.cells, 0, remaining);
        return;
      }

      appendSpan(std::span<const ScreenCell>{screen.cells}.subspan(first, end - first), first, remaining);
    }
  }

  void appendSpan(std::span<const ScreenCell> cells, std::size_t start, std::span<Byte> &output) {
    const Byte *begin = output.data();
    const CellStyle *previous = nullptr;

    for (const auto &cell : cells) {
      constexpr Byte style_changed_bit = 0x80;
      constexpr unsigned width_shift = 5;
      const bool changed = previous == nullptr || !(cell.style == *previous);
      u8::encode(static_cast<Byte>(cell.length | (static_cast<Byte>(cell.width) << width_shift) | (changed ? style_changed_bit : 0)), output);

      if (changed) {
        ValueCodec<CellStyle>::encode(cell.style, output);
      }

      std::copy_n(cell.text.data(), cell.length, output.data());
      output = output.subspan(cell.length);
      previous = &cell.style;
    }

    spans_.push_back(FrameSpan{
        .start = static_cast<std::uint32_t>(start),
        .count = static_cast<std::uint32_t>(cells.size()),
        .cells = {begin, static_cast<std::size_t>(output.data() - begin)},
    });
  }

  static constexpr std::size_t maximum_spans = 4096;
  static constexpr std::size_t maximum_cell_bytes = 31;
  static constexpr std::size_t maximum_metadata_bytes = 153098 + maximum_spans * 12 + 62;
#if TELAR_DIAGNOSTICS
  void recordFrame(std::size_t bytes, bool snapshot) noexcept {
    if (counters_ == nullptr) {
      return;
    }

    diagnostics::accumulate(counters_->frames);
    diagnostics::accumulate(counters_->frame_bytes, bytes);
    diagnostics::accumulate(counters_->frame_spans, spans_.size());
    diagnostics::accumulate(counters_->snapshots, snapshot);
    diagnostics::accumulate(counters_->cursor_only_frames, spans_.empty());
    for (const auto &span : spans_) {
      diagnostics::accumulate(counters_->frame_cells, span.count);
    }
  }

  diagnostics::FrameCounters *counters_ = nullptr;
#endif
  std::uint64_t pane_id_;
  Vector<ScreenCell, Memory> baseline_;
  Vector<Byte, Memory> cell_bytes_;
  Vector<Byte, Memory> payload_;
  Vector<FrameSpan, Memory> spans_;
  Vector<Byte, Memory> metadata_bytes_;
  Vector<Byte, Memory> previous_metadata_;
  std::uint64_t metadata_revision_ = 0;
  FrameBody previous_header_{};
  std::uint64_t next_frame_id_ = 1;
  std::uint64_t acknowledged_id_ = 0;
  std::uint64_t outstanding_id_ = 0;
  std::uint64_t observed_revision_ = 0;
  bool snapshot_pending_ = true;
};

}
