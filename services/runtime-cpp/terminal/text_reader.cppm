module;
#include "telar_platform/trace_macro.hpp"
#include <ghostty/vt.h>
#include <new>
#include <unistd.h>
#include <cerrno>
#include <limits.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <zlib.h>

#include "cell_layout.hpp"

#include <cstring>



#include "telar_base/diagnostics/config.hpp"

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/mman.h>
#include <cassert>

export module telar.runtime.terminal.text_reader;

import std;

export import telar.runtime.diagnostics.runtime_counters;


export import telar.runtime.diagnostics.operation;
export import telar.runtime.graphics.pane_media;
export import telar.runtime.graphics.prepared_images;


export import telar.runtime.terminal.osc_scanner;
export import telar.base.memory;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.config;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;

// Interface: terminal/text_metadata.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class TextMetadataCapture {
public:
  inline explicit TextMetadataCapture(Memory &memory)
      : links_(AllocatorRef<MetadataLink, Memory>{memory}),
        runs_(AllocatorRef<MetadataRun, Memory>{memory}),
        uris_(AllocatorRef<Byte, Memory>{memory}) {
    links_.reserve(maximum_links);
    runs_.reserve(maximum_runs);
    uris_.reserve(maximum_uri_bytes);
  }

  inline TextMetadata view(std::span<const Byte> row_flags) const noexcept {
    return TextMetadata{.status = status_,
                        .row_flags = row_flags,
                        .links = links_,
                        .runs = runs_,
                        .uris = uris_};
  }

  inline void capture(GhosttyRenderState state, GhosttyRenderStateRowIterator iterator, std::span<const Byte> row_flags, std::uint16_t columns) {
    links_.clear();
    runs_.clear();
    uris_.clear();
    status_ = MetadataStatus::complete;
    identities_.fill({});
    slots_.fill(0);
    checkGhostty(ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iterator));
    std::uint32_t row = 0;

    while (ghostty_render_state_row_iterator_next(iterator)) {
      if ((row_flags[row] & static_cast<Byte>(RowFlag::hyperlinks)) != 0) {
        captureRow(iterator, row * columns);
      }

      ++row;
    }
  }

private:
  struct Identity {
    std::string_view uri;
    std::string_view explicit_id;
    std::uint64_t implicit_id = 0;

    bool operator==(const Identity &) const = default;
  };

  inline static std::string_view stringView(GhosttyString value) noexcept {
    return {reinterpret_cast<const char *>(value.ptr), value.len};
  }

  inline static std::size_t hash(const Identity &identity) noexcept {
    std::size_t value = identity.implicit_id;
    for (const auto text : {identity.uri, identity.explicit_id}) {
      for (const unsigned char byte : text) {
        value = (value ^ byte) * 1099511628211ULL;
      }
    }

    return value;
  }

  inline std::optional<std::uint16_t> intern(const Identity &identity) {
    auto slot = hash(identity) % slots_.size();
    while (slots_[slot] != 0) {
      const auto index = static_cast<std::uint16_t>(slots_[slot] - 1);
      if (identities_[index] == identity) {
        return index;
      }

      slot = (slot + 1) % slots_.size();
    }

    if (links_.size() == maximum_links || identity.uri.size() > maximum_uri_length || identity.explicit_id.size() > maximum_uri_length || identity.uri.size() > maximum_uri_bytes - uris_.size()) {
      status_ = MetadataStatus::partial;
      return std::nullopt;
    }

    const auto index = static_cast<std::uint16_t>(links_.size());
    links_.push_back(MetadataLink{.offset = static_cast<std::uint32_t>(uris_.size()),
                                  .len = static_cast<std::uint16_t>(identity.uri.size())});
    uris_.insert(uris_.end(), identity.uri.begin(), identity.uri.end());
    identities_[index] = identity;
    slots_[slot] = index + 1;
    return index;
  }

  inline void captureRow(GhosttyRenderStateRowIterator iterator, std::uint32_t row_start) {
    auto reference = ghosttySized<GhosttyGridRef>();
    GhosttyCellsView cells{};
    checkGhostty(ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_GRID_REF, &reference));
    checkGhostty(ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS_RAW, &cells));
    bool continuing = false;

    for (std::uint16_t column = 0; column < cells.len; ++column) {
      const auto raw = cells.ptr[column];
      if (!cell_layout::hyperlink(raw) || cell_layout::wide(raw) == GHOSTTY_CELL_WIDE_SPACER_HEAD) {
        continuing = false;
        continue;
      }

      reference.x = column;
      GhosttyString uri{};
      GhosttyString explicit_id{};
      std::uint64_t implicit_id = 0;
      const auto result = ghostty_grid_ref_hyperlink(&reference, &uri, &explicit_id, &implicit_id);
      if (result == GHOSTTY_NO_VALUE || uri.len == 0) {
        continuing = false;
        continue;
      }

      checkGhostty(result);
      const auto index = intern(Identity{stringView(uri), stringView(explicit_id), implicit_id});
      if (!index) {
        continuing = false;
        continue;
      }

      if (continuing && runs_.back().link_index == *index) {
        ++runs_.back().len;
      } else if (runs_.size() != maximum_runs) {
        runs_.push_back(MetadataRun{.start = row_start + column,
                                    .len = 1,
                                    .link_index = *index});
      } else {
        status_ = MetadataStatus::partial;
        return;
      }

      continuing = true;
    }
  }

  static constexpr std::size_t maximum_links = 256;
  static constexpr std::size_t maximum_runs = 2048;
  static constexpr std::size_t maximum_uri_bytes = 65536;
  static constexpr std::size_t maximum_uri_length = 4096;
  Vector<MetadataLink, Memory> links_;
  Vector<MetadataRun, Memory> runs_;
  Vector<Byte, Memory> uris_;
  std::array<Identity, maximum_links> identities_{};
  std::array<std::uint16_t, maximum_links * 2> slots_{};
  MetadataStatus status_ = MetadataStatus::complete;
};

}
}

// Interface: terminal/screen.cppm
export {
namespace telar::runtime {

struct ScreenCell {
  std::array<Byte, 16> text{' '};
  Byte length = 1;
  CellWidth width = CellWidth::single;
  CellStyle style{};

  bool operator==(const ScreenCell &other) const noexcept {
    return std::memcmp(this, &other, sizeof(ScreenCell)) == 0;
  }

  inline Cell view() const noexcept {
    return Cell{width, style, std::span<const Byte>{text}.first(length)};
  }
};

static_assert(sizeof(ScreenCell) == 32);
static_assert(std::has_unique_object_representations_v<ScreenCell>);

template <Allocator Memory>
class Screen {
public:
  inline explicit Screen(Memory &memory)
      : cells(AllocatorRef<ScreenCell, Memory>{memory}),
        row_revisions(AllocatorRef<std::uint64_t, Memory>{memory}),
        row_flags(AllocatorRef<Byte, Memory>{memory}),
        metadata(memory) {}

  inline void reserve(std::uint16_t columns, std::uint16_t lines) {
    constexpr std::size_t maximum_cells = 130359;
    const auto count = static_cast<std::size_t>(columns) * lines;
    if (columns == 0 || lines == 0 || count > maximum_cells) {
      throw EncodingError{"Terminal size exceeds the wire limit"};
    }

    cells.reserve(count);
    row_revisions.reserve(lines);
    row_flags.reserve(lines);
  }

  inline void resize(std::uint16_t columns, std::uint16_t lines) {
    reserve(columns, lines);
    cells.resize(static_cast<std::size_t>(columns) * lines);
    row_revisions.resize(lines);
    row_flags.resize(lines);
    cols = columns;
    rows = lines;
    ++revision;
    ++metadata_revision;
    std::fill(row_revisions.begin(), row_revisions.end(), revision);
  }

  Vector<ScreenCell, Memory> cells;
  Vector<std::uint64_t, Memory> row_revisions;
  Vector<Byte, Memory> row_flags;
  TextMetadataCapture<Memory> metadata;
  std::uint64_t metadata_revision = 1;
  std::uint16_t cols = 0;
  std::uint16_t rows = 0;
  std::uint64_t revision = 0;
  Cursor cursor{};
  Mouse mouse{};
  InputModes input_modes{};
  PointerShape pointer_shape{};
  Scroll scroll{};
};

}
}

// Interface: terminal/cell_projection.cppm
export {
namespace telar::runtime {

class CellProjection {
public:
  void updateColors(GhosttyTerminal terminal, GhosttyRenderState render_state);
  void copyRow(GhosttyRenderStateRowIterator row, GhosttyRenderStateRowCells cells, std::span<ScreenCell> destination) const;

private:
  CellColor paletteColor(Byte index) const noexcept;
  CellColor resolveColor(const GhosttyStyleColor &color, CellColor fallback) const noexcept;
  CellStyle translateStyle(const GhosttyStyle &style) const noexcept;
  static void writeGrapheme(GhosttyRenderStateRowCells cells, ScreenCell &destination);

  GhosttyRenderStateColors colors_ = ghosttySized<GhosttyRenderStateColors>();
  std::array<Byte, 256> palette_overrides_{};
  CellStyle default_style_{};
};

}
}

// Interface: terminal/effects.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class TerminalEffects {
public:
  inline explicit TerminalEffects(Memory &memory)
      : clipboard(AllocatorRef<Byte, Memory>{memory}) {}

  inline void refresh(GhosttyTerminal terminal) {
    if (title_pending) {
      GhosttyString value{};
      checkGhostty(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &value));
      updateTitle({reinterpret_cast<const char *>(value.ptr), value.len});
      title_pending = false;
    }

    if (cwd_pending) {
      GhosttyString value{};
      checkGhostty(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_PWD, &value));
      updateCwd({reinterpret_cast<const char *>(value.ptr), value.len});
      cwd_pending = false;
    }
  }

  inline std::string_view title() const noexcept {
    return {title_.data(), title_length_};
  }

  inline std::string_view cwd() const noexcept {
    return {cwd_.data(), cwd_length_};
  }

  inline void setProgress(PaneProgressState state, std::optional<Byte> percent) noexcept {
    if (state == progress_state && percent == progress_percent) {
      return;
    }

    progress_state = state;
    progress_percent = percent;
    ++progress_revision;
  }

  Vector<Byte, Memory> clipboard;
  std::uint64_t title_revision = 1;
  std::uint64_t cwd_revision = 0;
  std::uint64_t clipboard_revision = 0;
  std::uint64_t progress_revision = 1;
  PaneProgressState progress_state = PaneProgressState::remove;
  std::optional<Byte> progress_percent;
  bool title_pending = false;
  bool cwd_pending = false;

private:
  inline void updateTitle(std::string_view raw) {
    std::array<char, 256> candidate{};
    std::size_t length = 0;
    while (!raw.empty()) {
      const auto first = static_cast<Byte>(raw.front());
      const std::size_t count = first < 0x80 ? 1 : first < 0xe0 ? 2
                                               : first < 0xf0   ? 3
                                                                : 4;
      if (raw.size() < count || count > candidate.size() - length) {
        break;
      }

      const auto sequence = raw.substr(0, count);
      raw.remove_prefix(count);
      if (count == 1 && (first < 0x20 || first == 0x7f)) {
        continue;
      }

      try {
        validateUtf8(sequence);
      } catch (const EncodingError &) {
        continue;
      }

      std::copy(sequence.begin(), sequence.end(), candidate.begin() + length);
      length += count;
    }

    if (title() != std::string_view{candidate.data(), length}) {
      title_ = candidate;
      title_length_ = length;
      ++title_revision;
    }
  }

  inline void updateCwd(std::string_view raw) {
    bool encoded = false;
    for (const auto prefix : {std::string_view{"file://"}, std::string_view{"kitty-shell-cwd://"}}) {
      if (raw.starts_with(prefix)) {
        raw.remove_prefix(prefix.size());
        const auto slash = raw.find('/');
        if (slash == std::string_view::npos) {
          return;
        }
        raw.remove_prefix(slash);
        encoded = true;
        break;
      }
    }

    if (raw.empty() || raw.front() != '/' || raw.size() > cwd_.size()) {
      return;
    }

    std::array<char, 4096> candidate{};
    std::size_t length = 0;
    while (!raw.empty()) {
      char character = raw.front();
      if (encoded && character == '%') {
        if (raw.size() < 3) {
          return;
        }
        unsigned byte = 0;
        const auto parsed = std::from_chars(raw.data() + 1, raw.data() + 3, byte, 16);
        if (parsed.ec != std::errc{} || parsed.ptr != raw.data() + 3) {
          return;
        }
        character = static_cast<char>(byte);
        raw.remove_prefix(2);
      }
      if (character == '\0') {
        return;
      }
      candidate[length++] = character;
      raw.remove_prefix(1);
    }

    if (cwd() != std::string_view{candidate.data(), length}) {
      cwd_ = candidate;
      cwd_length_ = length;
      ++cwd_revision;
    }
  }

  std::array<char, 256> title_{};
  std::array<char, 4096> cwd_{};
  std::size_t title_length_ = 0;
  std::size_t cwd_length_ = 0;
};

}
}

// Interface: terminal/frame_sync.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class FrameSync {
public:
  inline explicit FrameSync(Memory &memory, std::uint64_t pane_id)
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

  inline bool acknowledge(std::uint64_t frame_id) noexcept {
    TELAR_DIAGNOSTIC(diagnostics::TimedScope timing{counters_ == nullptr ? nullptr : &counters_->ack});
    if (frame_id == 0 || frame_id != outstanding_id_) {
      return false;
    }

    acknowledged_id_ = frame_id;
    outstanding_id_ = 0;
    return true;
  }

  inline void requestSnapshot() noexcept {
    snapshot_pending_ = true;
  }

  inline bool needsSnapshot(const Screen<Memory> &screen) const noexcept {
    return snapshot_pending_ || screen.cols != previous_header_.cols || screen.rows != previous_header_.rows;
  }

  inline bool waitingForAck() const noexcept {
    return outstanding_id_ != 0;
  }

  inline bool waitingForAck(const Screen<Memory> &screen) const noexcept {
    return waitingForAck() && screen.cols == previous_header_.cols && screen.rows == previous_header_.rows;
  }

  inline std::uint64_t observedRevision() const noexcept {
    return observed_revision_;
  }

  inline std::span<const Byte> prepare(const Screen<Memory> &screen) {
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
  inline void setCounters(diagnostics::FrameCounters &counters) noexcept {
    counters_ = &counters;
  }
#endif

private:
  inline FrameBody frameHeader(const Screen<Memory> &screen) const noexcept {
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

  inline static bool sameHeader(const FrameBody &left, const FrameBody &right) noexcept {
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

  inline void appendDamage(const Screen<Memory> &screen, std::span<Byte> &remaining) {
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

  inline void appendSpan(std::span<const ScreenCell> cells, std::size_t start, std::span<Byte> &output) {
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
  inline void recordFrame(std::size_t bytes, bool snapshot) noexcept {
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
}

// Interface: terminal/terminal.cppm
export {
namespace telar::runtime {

enum class TerminalPurpose {
  interactive,
  separate_media,
  observation
};

template <Allocator Memory>
class Terminal {
public:
  inline explicit Terminal(Memory &memory, TerminalSize size, TerminalPurpose purpose = TerminalPurpose::interactive, std::shared_ptr<PtyResponseQueue> responses = {}, GraphicsQueryResources resources = {})
      : screen(memory),
        effects(memory),
        graphics(memory),
        allocator_(memory),
        responses_(responses ? std::move(responses) : std::allocate_shared<PtyResponseQueue>(AllocatorRef<PtyResponseQueue, Memory>{memory})),
        response_outbox_(memory, *responses_),
        control_(memory, *responses_, purpose != TerminalPurpose::observation, resources),
        pending_control_input_(memory, control_input_limit),
        purpose_(purpose) {
    screen.resize(size.cols, size.rows);
    checkGhostty(ghostty_terminal_new(allocator_.get(), terminal_.output(), size.cols, size.rows));
    checkGhostty(ghostty_render_state_new(allocator_.get(), render_state_.output()));
    checkGhostty(ghostty_render_state_row_iterator_new(allocator_.get(), row_iterator_.output()));
    checkGhostty(ghostty_render_state_row_cells_new(allocator_.get(), row_cells_.output()));
    control_.bind(terminal_.get(), render_state_.get(), purpose == TerminalPurpose::separate_media);

    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_USERDATA, this));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_WRITE_PTY, reinterpret_cast<const void *>(&receiveResponse)));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, reinterpret_cast<const void *>(&titleChanged)));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_PWD_CHANGED, reinterpret_cast<const void *>(&cwdChanged)));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, reinterpret_cast<const void *>(&clipboardWrite)));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT, reinterpret_cast<const void *>(&progressReported)));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_SIZE, reinterpret_cast<const void *>(&reportSize)));
    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, default_palette_.data()));
    const std::size_t scrollback_bytes = 10'000'000;
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback_bytes));

    const GhosttyColorRgb foreground{255, 255, 255};
    const GhosttyColorRgb background{0, 0, 0};
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background));
    const bool blink = true;
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &blink));
    const bool disabled = false;
    const std::size_t image_storage = purpose == TerminalPurpose::interactive ? graphics_screen_bytes : 0;
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &image_storage));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE, &disabled));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE, nullptr));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM, &disabled));
    if (purpose != TerminalPurpose::interactive) {
      checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_KITTY_PROTOCOL, &disabled));
    }
    resize(size);
  }

  inline std::span<const Byte> encodeKey(GhosttyKey key, GhosttyMods modifiers, std::span<Byte> destination) {
    GhosttyHandle<GhosttyKeyEncoder, ghostty_key_encoder_free> encoder;
    GhosttyHandle<GhosttyKeyEvent, ghostty_key_event_free> event;
    checkGhostty(ghostty_key_encoder_new(allocator_.get(), encoder.output()));
    checkGhostty(ghostty_key_event_new(allocator_.get(), event.output()));
    ghostty_key_encoder_setopt_from_terminal(encoder.get(), terminal_.get());
    ghostty_key_event_set_action(event.get(), GHOSTTY_KEY_ACTION_PRESS);
    ghostty_key_event_set_key(event.get(), key);
    ghostty_key_event_set_mods(event.get(), modifiers);
    if (key == GHOSTTY_KEY_C) {
      ghostty_key_event_set_unshifted_codepoint(event.get(), 'c');
    }

    std::size_t length = 0;
    checkGhostty(ghostty_key_encoder_encode(encoder.get(), event.get(), reinterpret_cast<char *>(destination.data()), destination.size(), &length));
    return destination.first(length);
  }

  inline void feed(std::span<const Byte> bytes) {
    TELAR_TRACE("terminal.feed");
    ++content_revision_;
    resumeControl();
    if (hasPendingControl()) {
      pending_control_input_.append(bytes);
    } else {
      const auto consumed = feedControl(bytes);
      if (consumed < bytes.size()) {
        pending_control_input_.append(bytes.subspan(consumed));
      }
    }
    finishControlInput();
  }

  inline void resumeControl() {
    const bool pending = hasPendingControl();
    if (!pending) {
      return;
    }
    if (control_.awaitingMedia()) {
      if (media_ == nullptr || !media_->idle()) {
        return;
      }
      control_.mediaComplete();
    }
    if (!response_outbox_.drain()) {
      return;
    }
    const auto consumed = feedControl(pending_control_input_.readable());
    pending_control_input_.consume(consumed);
    if (pending) {
      ++content_revision_;
      finishControlInput();
    }
  }

  // Pane owns both objects and destroys Terminal before PaneMedia. Only the
  // runtime touches this borrowed ingress port; workers own sealed batches.
  inline void attachMedia(PaneMedia<Memory> &media) noexcept {
    assert(purpose_ == TerminalPurpose::separate_media && media_ == nullptr);
    media_ = &media;
    media.requireOrderedInput();
    control_.enableMediaBoundaries();
  }

  inline bool hasPendingControl() const noexcept {
    return response_outbox_.pending() || control_.blocked() || !pending_control_input_.empty();
  }

  inline void configureClientFacts(control::ClientFacts facts) {
    control_.configureFacts(facts);
    control_.publishReports();
  }

  inline control::Policy &controlPolicy() noexcept {
    return control_.policy;
  }

  inline control::Clipboard<Memory> &clipboardControl() noexcept {
    return control_.clipboard();
  }

  inline bool pasteEvents() const noexcept {
    return control_.pasteEvents();
  }

  inline void resize(TerminalSize size) {
    if (hasSize(size)) {
      return;
    }

    screen.reserve(size.cols, size.rows);
    checkGhostty(ghostty_terminal_resize(terminal_.get(), size.cols, size.rows, size.cell_width_px, size.cell_height_px));
    if (screen.cols != size.cols || screen.rows != size.rows) {
      screen.resize(size.cols, size.rows);
    }

    size_ = size;
    control_.configureSize(size);
    resumeControl();
    ++content_revision_;
    dirty_ = true;
    force_ = true;
  }

  inline bool hasSize(TerminalSize size) const noexcept {
    return size_.cols == size.cols && size_.rows == size.rows && size_.cell_width_px == size.cell_width_px && size_.cell_height_px == size.cell_height_px;
  }

  inline void configureColors(const ConfigureTerminalColors &colors) {
    const auto foreground = colors.foreground ? GhosttyColorRgb{(*colors.foreground)[0], (*colors.foreground)[1], (*colors.foreground)[2]} : GhosttyColorRgb{255, 255, 255};
    const auto background = colors.background ? GhosttyColorRgb{(*colors.background)[0], (*colors.background)[1], (*colors.background)[2]} : GhosttyColorRgb{};
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground));
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background));
    auto palette = default_palette_;
    if (colors.palette) {
      for (std::size_t index = 0; index < colors.palette->size() / 3; ++index) {
        palette[index] = {(*colors.palette)[index * 3], (*colors.palette)[index * 3 + 1], (*colors.palette)[index * 3 + 2]};
      }
    }
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, palette.data()));
    control_.externalColorsChanged();
    dirty_ = true;
    force_ = true;
  }

  inline void configureCursorColor(std::optional<std::array<Byte, 3>> color) {
    const GhosttyColorRgb rgb = color ? GhosttyColorRgb{(*color)[0], (*color)[1], (*color)[2]} : GhosttyColorRgb{};
    checkGhostty(ghostty_terminal_set(terminal_.get(), GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, color ? &rgb : nullptr));
    control_.externalColorsChanged();
    dirty_ = true;
  }

  inline bool mode(GhosttyMode mode) const {
    GhosttyTerminalModeConfig query{.mode = mode,
                                    .value = false};
    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_MODE, &query));
    return query.value;
  }

  inline bool outputSettled() const {
    bool ground = false;
    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_VT_GROUND, &ground));
    return ground && control_.ground() && !hasPendingControl() && !mode(GHOSTTY_MODE_SYNC_OUTPUT);
  }

  inline void refresh() {
    TELAR_TRACE("terminal.refresh");
    if (!dirty_) {
      return;
    }

    checkGhostty(ghostty_render_state_update(render_state_.get(), terminal_.get()));
    GhosttyRenderStateDirty damage{};
    checkGhostty(ghostty_render_state_get(render_state_.get(), GHOSTTY_RENDER_STATE_DATA_DIRTY, &damage));
    auto iterator = row_iterator_.get();
    checkGhostty(ghostty_render_state_get(render_state_.get(), GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iterator));
    projection_.updateColors(terminal_.get(), render_state_.get());

    ++screen.revision;
    const bool all_rows = force_ || damage == GHOSTTY_RENDER_STATE_DIRTY_FULL;
    bool rebuild_links = all_rows;
    bool metadata_changed = all_rows;
    std::uint16_t row = 0;
    while (all_rows ? ghostty_render_state_row_iterator_next(iterator) : ghostty_render_state_row_iterator_next_dirty(iterator, &row)) {
      auto destination = std::span<ScreenCell>{screen.cells}.subspan(static_cast<std::size_t>(row) * screen.cols, screen.cols);
      projection_.copyRow(iterator, row_cells_.get(), destination);
      screen.row_revisions[row] = screen.revision;
      const auto flags = readRowFlags(iterator);
      rebuild_links |= ((screen.row_flags[row] | flags) & static_cast<Byte>(RowFlag::hyperlinks)) != 0;
      metadata_changed |= screen.row_flags[row] != flags;
      screen.row_flags[row] = flags;

      if (all_rows) {
        ++row;
      }
    }

    if (rebuild_links) {
      screen.metadata.capture(render_state_.get(), iterator, screen.row_flags, screen.cols);
    }

    if (rebuild_links || metadata_changed) {
      ++screen.metadata_revision;
    }

    if (purpose_ == TerminalPurpose::interactive) {
      graphics.update(terminal_.get());
    }
    updateCursor();
    updateModes();
    updateScroll();
    checkGhostty(ghostty_render_state_clean(render_state_.get()));
    dirty_ = false;
    force_ = false;
  }

  inline void scrollTo(std::uint32_t row) {
    GhosttyTerminalScrollViewport viewport{.tag = GHOSTTY_SCROLL_VIEWPORT_ROW,
                                           .value = {.row = row}};
    ghostty_terminal_scroll_viewport(terminal_.get(), viewport);
    dirty_ = true;
    force_ = true;
  }

  inline void scrollToBottom() {
    GhosttyTerminalScrollViewport viewport{.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM,
                                           .value = {}};
    ghostty_terminal_scroll_viewport(terminal_.get(), viewport);
    dirty_ = true;
    force_ = true;
  }

  inline std::span<const Byte> responses() const noexcept {
    return responses_->readable();
  }

  inline void consumeResponses(std::size_t count) {
    responses_->consume(count);
    resumeControl();
  }

  inline void discardResponses() noexcept {
    response_outbox_.discard();
    responses_->clear();
  }

  inline void abortControl() noexcept {
    media_ = nullptr;
    control_.discard();
    response_outbox_.discard();
    pending_control_input_.clear();
    responses_->close();
  }

  inline bool dirty() const noexcept {
    return dirty_;
  }

  inline std::uint64_t contentRevision() const noexcept {
    return content_revision_;
  }

  inline GhosttyTerminal handle() const noexcept {
    return terminal_.get();
  }

  inline const GhosttyAllocator *allocator() const noexcept {
    return allocator_.get();
  }

#if TELAR_DIAGNOSTICS
  inline diagnostics::TerminalStorageSnapshot storageMetrics() const {
    std::size_t page_bytes = 0;
    checkGhostty(ghostty_terminal_page_bytes(terminal_.get(), &page_bytes));
    return {page_bytes, screen.cells.size() * sizeof(ScreenCell)};
  }
#endif

  Screen<Memory> screen;
  TerminalEffects<Memory> effects;
  GraphicsStorage<Memory> graphics;

private:
  inline std::size_t feedControl(std::span<const Byte> bytes) {
    const auto atomic = media_ != nullptr && control_.ground() && !control_.blocked() ? atomicMediaPrefix(bytes) : 0;
    const auto consumed = atomic != 0 ? control_.feedAtomicMedia(bytes.first(atomic)) : control_.feed(bytes);
    if (media_ != nullptr && consumed != 0) {
      media_->output(bytes.first(consumed));
      if (media_->failed()) {
        throw TerminalError{GHOSTTY_OUT_OF_MEMORY};
      }
    }
    return consumed;
  }

  inline static std::size_t atomicMediaPrefix(std::span<const Byte> bytes) noexcept {
    constexpr unsigned maximum_frames = 8;
    constexpr std::size_t maximum_pixels_bytes = GraphicsLimits::maximum_pane_bytes / 2;
    constexpr std::string_view filename_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";
    const std::string_view input{reinterpret_cast<const char *>(bytes.data()), bytes.size()};
    std::size_t consumed = 0;
    std::size_t pixels = 0;
    for (unsigned count = 0; count < maximum_frames; ++count) {
      const auto frame = AtomicFrame::at(input, consumed);
      if (!frame || frame->control.byte_count > maximum_pixels_bytes - pixels || frame->encoded_name.find_first_not_of(filename_alphabet) != std::string_view::npos) {
        break;
      }
      consumed = frame->end;
      pixels += frame->control.byte_count;
    }
    return consumed;
  }

  inline void finishControlInput() {
    response_outbox_.drain();
    dirty_ = true;
    effects.refresh(terminal_.get());
    if (purpose_ == TerminalPurpose::interactive) {
      graphics.update(terminal_.get());
    }

    bool processing_error = false;
    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_VT_PROCESSING_ERROR, &processing_error));
    if (processing_error) {
      throw TerminalError{GHOSTTY_OUT_OF_MEMORY};
    }
  }

  inline static void titleChanged(GhosttyTerminal, void *context) noexcept {
    static_cast<Terminal *>(context)->effects.title_pending = true;
  }

  inline static void cwdChanged(GhosttyTerminal, void *context) noexcept {
    static_cast<Terminal *>(context)->effects.cwd_pending = true;
  }

  inline static GhosttyClipboardWriteResult clipboardWrite(GhosttyTerminal, void *context, const GhosttyClipboardWrite *write) noexcept {
    // Clipboard protocols are owned by the native controller. A backend
    // callback indicates a filter failure and must never bypass its policy.
    (void)context;
    (void)write;
    return GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED;
  }

  inline static void progressReported(GhosttyTerminal, void *context, const GhosttyTerminalProgressReport *report) noexcept {
    if (report->size < sizeof(GhosttyTerminalProgressReport)) {
      return;
    }

    const auto percent = report->progress >= 0 ? std::optional<Byte>{static_cast<Byte>(report->progress)} : std::nullopt;
    static_cast<Terminal *>(context)->effects.setProgress(static_cast<PaneProgressState>(report->state), percent);
  }

  inline static bool reportSize(GhosttyTerminal, void *context, GhosttySizeReportSize *output) noexcept {
    const auto size = static_cast<Terminal *>(context)->size_;
    if (size.cell_width_px == 0 || size.cell_height_px == 0) {
      return false;
    }
    *output = {.rows = size.rows,
               .columns = size.cols,
               .cell_width = size.cell_width_px,
               .cell_height = size.cell_height_px};
    return true;
  }

  inline static void receiveResponse(GhosttyTerminal, void *context, const Byte *bytes, std::size_t count) noexcept {
    auto &terminal = *static_cast<Terminal *>(context);

    constexpr std::string_view graphics_prefix = "\x1b_G";
    if (terminal.purpose_ != TerminalPurpose::observation && count >= graphics_prefix.size() && std::memcmp(bytes, graphics_prefix.data(), graphics_prefix.size()) == 0) {
      try {
        terminal.response_outbox_.append({bytes, count});
      } catch (...) {
        terminal.control_.failWrite();
        terminal.responses_->stopProducing();
      }
    }
  }

  inline static Byte readRowFlags(GhosttyRenderStateRowIterator iterator) {
    GhosttyRow row{};
    checkGhostty(ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_RAW, &row));
    bool wrap = false;
    bool continuation = false;
    bool hyperlinks = false;
    checkGhostty(ghostty_row_get(row, GHOSTTY_ROW_DATA_WRAP, &wrap));
    checkGhostty(ghostty_row_get(row, GHOSTTY_ROW_DATA_WRAP_CONTINUATION, &continuation));
    checkGhostty(ghostty_row_get(row, GHOSTTY_ROW_DATA_HYPERLINK, &hyperlinks));

    Byte flags = 0;
    if (wrap) {
      flags |= static_cast<Byte>(RowFlag::wrap);
      GhosttyCellsView cells{};
      checkGhostty(ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS_RAW, &cells));
      if (cells.len != 0 && cell_layout::wide(cells.ptr[cells.len - 1]) == GHOSTTY_CELL_WIDE_SPACER_HEAD) {
        flags |= static_cast<Byte>(RowFlag::wide_padding);
      }
    }
    if (continuation) {
      flags |= static_cast<Byte>(RowFlag::continuation);
    }
    if (hyperlinks) {
      flags |= static_cast<Byte>(RowFlag::hyperlinks);
    }
    return flags;
  }

  inline void updateCursor() {
    auto cursor = ghosttySized<GhosttyRenderStateCursor>();
    checkGhostty(ghostty_render_state_get(render_state_.get(), GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor));
    screen.cursor.visible = cursor.visible && cursor.viewport_has_value;
    screen.cursor.x = screen.cursor.visible ? cursor.viewport_x : 0;
    screen.cursor.y = screen.cursor.visible ? cursor.viewport_y : 0;
    screen.cursor.blink = cursor.blinking;
    bool default_shape = false;
    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_CURSOR_IS_DEFAULT, &default_shape));
    if (default_shape || !screen.cursor.visible) {
      screen.cursor.shape = CursorShape::default_shape;
      if (!screen.cursor.visible) {
        screen.cursor.blink = true;
      }
      return;
    }

    switch (cursor.visual_style) {
    case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR:
      screen.cursor.shape = CursorShape::bar;
      break;
    case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK:
      screen.cursor.shape = CursorShape::block;
      break;
    case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE:
      screen.cursor.shape = CursorShape::underline;
      break;
    case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW:
      screen.cursor.shape = CursorShape::hollow;
      break;
    default:
      screen.cursor.shape = CursorShape::default_shape;
      break;
    }
  }

  inline void updateModes() {
    screen.input_modes.cursor_keys = mode(GHOSTTY_MODE_DECCKM);
    screen.input_modes.keypad_keys = mode(GHOSTTY_MODE_KEYPAD_KEYS);
    screen.input_modes.bracketed_paste = mode(GHOSTTY_MODE_BRACKETED_PASTE);
    screen.input_modes.paste_events = control_.pasteEvents();
    screen.input_modes.focus_events = mode(GHOSTTY_MODE_FOCUS_EVENT);
    screen.input_modes.alternate_scroll = mode(GHOSTTY_MODE_ALT_SCROLL);
    GhosttyTerminalScreen active_screen{};
    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &active_screen));
    screen.input_modes.alternate_screen = active_screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE;
    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &screen.input_modes.kitty_keyboard_flags));

    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_MODIFY_OTHER_KEYS_2, &screen.input_modes.modify_other_keys_2));
    GhosttyString pointer{};
#if defined(GHOSTTY_TELAR_STATE_VERSION) && GHOSTTY_TELAR_STATE_VERSION >= 2
    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_MOUSE_SHAPE_NAME, &pointer));
#else
    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_MOUSE_SHAPE, &pointer));
#endif
    static constexpr std::array<std::string_view, 34> shapes{
        "default",
        "context_menu",
        "help",
        "pointer",
        "progress",
        "wait",
        "cell",
        "crosshair",
        "text",
        "vertical_text",
        "alias",
        "copy",
        "move",
        "no_drop",
        "not_allowed",
        "grab",
        "grabbing",
        "all_scroll",
        "col_resize",
        "row_resize",
        "n_resize",
        "e_resize",
        "s_resize",
        "w_resize",
        "ne_resize",
        "nw_resize",
        "se_resize",
        "sw_resize",
        "ew_resize",
        "ns_resize",
        "nesw_resize",
        "nwse_resize",
        "zoom_in",
        "zoom_out",
    };
    const std::string_view shape{reinterpret_cast<const char *>(pointer.ptr), pointer.len};
    const auto found = std::find(shapes.begin(), shapes.end(), shape);
    screen.pointer_shape = found == shapes.end() ? PointerShape::default_shape : static_cast<PointerShape>(found - shapes.begin());

    screen.mouse.tracking = mode(GHOSTTY_MODE_ANY_MOUSE)      ? MouseTracking::any
                            : mode(GHOSTTY_MODE_BUTTON_MOUSE) ? MouseTracking::button
                            : mode(GHOSTTY_MODE_NORMAL_MOUSE) ? MouseTracking::normal
                            : mode(GHOSTTY_MODE_X10_MOUSE)    ? MouseTracking::x10
                                                              : MouseTracking::none;
    screen.mouse.sgr = mode(GHOSTTY_MODE_SGR_MOUSE);
    screen.mouse.pixels = mode(GHOSTTY_MODE_SGR_PIXELS_MOUSE);
  }

  inline void updateScroll() {
    GhosttyTerminalScrollbar scrollbar{};
    checkGhostty(ghostty_terminal_get(terminal_.get(), GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar));
    screen.scroll.total_rows = static_cast<std::uint32_t>(std::min<std::uint64_t>(scrollbar.total, UINT32_MAX));
    screen.scroll.offset = static_cast<std::uint32_t>(std::min<std::uint64_t>(scrollbar.offset, UINT32_MAX));
  }

  GhosttyAllocatorBridge<Memory> allocator_;
  TerminalHandle terminal_;
  RenderStateHandle render_state_;
  RowIteratorHandle row_iterator_;
  RowCellsHandle row_cells_;
  std::shared_ptr<PtyResponseQueue> responses_;
  ResponseOutbox<Memory> response_outbox_;
  PaneMedia<Memory> *media_ = nullptr;
  static constexpr std::size_t control_input_limit = 128 * 1024;
  control::Engine<Memory> control_;
  ByteQueue<Memory> pending_control_input_;
  TerminalPurpose purpose_;
  CellProjection projection_;
  TerminalSize size_{};
  std::array<GhosttyColorRgb, 256> default_palette_{};
  bool dirty_ = true;
  bool force_ = true;
  std::uint64_t content_revision_ = 1;
};

}
}

// Interface: terminal/selection_formatter.cppm
export {
namespace telar::runtime {

enum class TrailingSpaces : bool {
  kept,
  trimmed
};

// Plain text of `selection`. Pane reads keep the spaces a program wrote, as
// Zig's `Screen.dumpString`; copies trim them, as `Screen.selectionString`.
template <Allocator Memory>
void formatTerminalSelection(Terminal<Memory> &terminal, const GhosttySelection &selection, bool unwrap, TrailingSpaces spaces, GhosttyWriter writer) {
  auto options = ghosttySized<GhosttyFormatterTerminalOptions>();
  options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
  options.unwrap = unwrap;
  options.trim = spaces == TrailingSpaces::trimmed;
  options.selection = &selection;
  options.extra = ghosttySized<GhosttyFormatterTerminalExtra>();
  options.extra.screen = ghosttySized<GhosttyFormatterScreenExtra>();
  FormatterHandle formatter;
  checkGhostty(ghostty_formatter_terminal_new(terminal.allocator(), formatter.output(), terminal.handle(), options));
  checkGhostty(ghostty_formatter_format(formatter.get(), writer));
}

}
}

// Interface: terminal/text_reader.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class TextReader {
public:
  inline explicit TextReader(Memory &memory, Terminal<Memory> &terminal, std::size_t capacity)
      : terminal_(terminal),
        bytes_(AllocatorRef<Byte, Memory>{memory}) {
    bytes_.resize(capacity);
  }

  inline void read(PaneTextSource source, std::uint16_t wanted_rows) {
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
    format(selection, false, TrailingSpaces::kept);
  }

  inline void copy(const CopySelection &request) {
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
    format(selection, true, TrailingSpaces::trimmed);
  }

  inline std::span<const Byte> bytes() const noexcept {
    return std::span<const Byte>{bytes_}.first(length_);
  }

  inline std::string_view text() const noexcept {
    return {reinterpret_cast<const char *>(bytes_.data()), length_};
  }

  inline bool truncated() const noexcept {
    return wrapped_;
  }

private:
  inline std::uint32_t totalRows() const {
    std::size_t count = 0;
    checkGhostty(ghostty_terminal_get(terminal_.handle(), GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &count));
    return static_cast<std::uint32_t>(std::min<std::size_t>(count, UINT32_MAX));
  }

  inline GhosttyGridRef reference(GhosttyPointTag tag, GhosttyPointCoordinate coordinate) const {
    auto result = ghosttySized<GhosttyGridRef>();
    checkGhostty(ghostty_terminal_grid_ref(terminal_.handle(), GhosttyPoint{.tag = tag, .value = {.coordinate = coordinate}}, &result));
    return result;
  }

  inline bool rowIsBlank(GhosttyPointTag tag, std::uint32_t row) const {
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

  inline void format(const GhosttySelection &selection, bool unwrap, TrailingSpaces spaces) {
    formatTerminalSelection(terminal_, selection, unwrap, spaces, GhosttyWriter{.write = receive, .userdata = this});

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

  inline static bool receive(void *context, const Byte *bytes, std::size_t count) noexcept {
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

template <Allocator Memory>
TextReader(Memory &memory, Terminal<Memory> &terminal, std::size_t capacity) -> TextReader<Memory>;

}
}
