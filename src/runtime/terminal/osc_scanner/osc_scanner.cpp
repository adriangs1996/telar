module;
#include <cassert>
#include <ghostty/vt.h>

#include <cstdint>

#include "cell_layout.hpp"
#include "terminal/ghostty_grid.hpp"

module telar.runtime.terminal.osc_scanner;

namespace telar::runtime {

  void FramePacer::configure(std::chrono::nanoseconds interval) noexcept {
    interval_ = interval;
  }

  void FramePacer::noteInput(Time time) noexcept {
    if (time != last_input_) {
      last_input_ = time;
      input_frames_left_ = input_burst;
    }
  }

  auto FramePacer::deadline(Time now) const noexcept -> std::optional<Time> {
    const bool input_recent = last_input_ && input_frames_left_ != 0 && now - *last_input_ < input_grace;
    if (available(now) != 0 || input_recent) {
      return std::nullopt;
    }

    return anchor_.value_or(now) + interval_;
  }

  void FramePacer::record(Time now, std::optional<Time> scheduled) noexcept {
    const auto credits = available(now);
    if (credits == 0 && !scheduled && input_frames_left_ != 0) {
      --input_frames_left_;
    }

    credits_ = credits == 0 ? 0 : credits - 1;
    anchor_ = scheduled ? *scheduled + interval_ * ((now - *scheduled) / interval_) : now;
  }

  unsigned FramePacer::available(Time now) const noexcept {
    if (!anchor_) {
      return idle_burst;
    }

    const auto refill = std::max(Clock::duration::zero(), now - *anchor_) / interval_;

    return static_cast<unsigned>(std::min<std::int64_t>(idle_burst, credits_ + refill));
  }

  InputEvent InputScanner::feed(std::span<const std::uint8_t> bytes) noexcept {
    InputEvent event;

    for (const auto byte : bytes) {
      consume(byte, event);
    }

    return event;
  }

  void InputScanner::reset() noexcept {
    state_ = State::ground;
    parameter_ = 0;
    has_parameter_ = false;
    typed_length_ = 0;
    typed_exact_ = true;
  }

  void InputScanner::clearSensitive() noexcept {
    eraseSensitive(typed_.data(), typed_.size());
    reset();
  }

  std::optional<std::string_view> InputScanner::typedText() const noexcept {
    if (!typed_exact_) {
      return std::nullopt;
    }

    return std::string_view{typed_.data(), typed_length_};
  }

  void InputScanner::consume(std::uint8_t byte, InputEvent& event) noexcept {
    const auto control = static_cast<ControlByte>(byte);

    switch (state_) {
    case State::ground:
      if (control == ControlByte::escape) {
        state_ = State::escape;
        typed_exact_ = false;
      } else if (control == ControlByte::carriage_return || control == ControlByte::newline) {
        event.submitted = true;
      } else if (control == ControlByte::cancel) {
        event.cancelled = true;
      } else if (control == ControlByte::backspace || control == ControlByte::delete_previous) {
        if (typed_length_ != 0) {
          --typed_length_;
        }
      } else if (control != ControlByte::clear_screen) {
        if (byte >= ' ' && byte <= '~' && typed_length_ < typed_.size()) {
          typed_[typed_length_++] = static_cast<char>(byte);
        } else {
          typed_exact_ = false;
        }
      }

      break;
    case State::escape:
      if (byte == '[') {
        startSequence(State::csi);
      } else {
        state_ = State::ground;
      }

      break;
    case State::csi:
      sequenceByte(byte, false);
      break;
    case State::paste:
      if (control == ControlByte::escape) {
        state_ = State::paste_escape;
      }

      break;
    case State::paste_escape:
      if (byte == '[') {
        startSequence(State::paste_csi);
      } else {
        state_ = State::paste;
      }

      break;
    case State::paste_csi:
      sequenceByte(byte, true);
      break;
    }
  }

  void InputScanner::startSequence(State state) noexcept {
    state_ = state;
    parameter_ = 0;
    has_parameter_ = false;
  }

  void InputScanner::sequenceByte(std::uint8_t byte, bool pasted) noexcept {
    if (byte >= '0' && byte <= '9') {
      has_parameter_ = true;
      const auto next = static_cast<std::uint32_t>(parameter_) * 10 + byte - '0';

      parameter_ = static_cast<std::uint16_t>(next > UINT16_MAX ? UINT16_MAX : next);
      return;
    }

    if (byte == '~' && has_parameter_) {
      if (!pasted && parameter_ == static_cast<std::uint16_t>(PasteMarker::begin)) {
        state_ = State::paste;
        return;
      }

      if (pasted && parameter_ == static_cast<std::uint16_t>(PasteMarker::end)) {
        state_ = State::ground;
        return;
      }
    }

    state_ = pasted ? State::paste : State::ground;
  }

  auto OscScanner::next(std::uint8_t byte) noexcept -> Event {
    const auto control = static_cast<ControlByte>(byte);

    switch (state_) {
    case State::ground:
      if (control == ControlByte::escape) {
        state_ = State::escape;
      }

      return Event::none;
    case State::escape:
      if (byte == ']') {
        state_ = State::osc;
        return Event::start;
      }

      state_ = State::ground;
      return Event::none;
    case State::osc:
      if (control == ControlByte::bell) {
        state_ = State::ground;
        return Event::end;
      }

      if (control == ControlByte::escape) {
        state_ = State::osc_escape;
        return Event::none;
      }

      return Event::payload;
    case State::osc_escape:
      if (byte == '\\') {
        state_ = State::ground;
        return Event::end;
      }

      state_ = control == ControlByte::escape ? State::escape : State::ground;
      return Event::none;
    }

    return Event::none;
  }

  template <Allocator Memory>
  ResponseOutbox<Memory>::ResponseOutbox(Memory& memory, std::shared_ptr<PtyResponseQueue> queue)
      : overflow_(AllocatorRef<std::uint8_t, Memory>{memory}),
        queue_(std::move(queue)) {}

  template <Allocator Memory>
  ResponseOutbox<Memory>::~ResponseOutbox() {
    discard();
  }

  template <Allocator Memory>
  void ResponseOutbox<Memory>::append(std::span<const std::uint8_t> response) {
    if (response.empty() || queue_->closed()) {
      return;
    }

    if (response.size() > PtyResponseQueue::message_byte_capacity || response.size() + header_bytes > maximum_bytes - size_) {
      throw std::length_error{"Graphics acknowledgement exceeds its staging budget"};
    }

    const auto length = static_cast<std::uint16_t>(response.size());
    const auto required = size_ + header_bytes + response.size();
    if (overflow_.empty() && required <= inline_.size()) {
      std::memcpy(inline_.data() + size_, &length, header_bytes);
      std::memcpy(inline_.data() + size_ + header_bytes, response.data(), response.size());
    } else {
      if (required > overflow_.capacity()) {
        overflow_.reserve(std::min(maximum_bytes, std::max(required, std::max(inline_bytes * 2, overflow_.capacity() * 2))));
      }

      if (overflow_.empty()) {
        overflow_.insert(overflow_.end(), inline_.begin(), inline_.begin() + size_);
      }

      const auto* header = reinterpret_cast<const std::uint8_t*>(&length);

      overflow_.insert(overflow_.end(), header, header + header_bytes);
      overflow_.insert(overflow_.end(), response.begin(), response.end());
    }

    size_ = required;
    if (!priority_) {
      priority_ = queue_->retainWorkerPriority();
    }
  }

  template <Allocator Memory>
  bool ResponseOutbox<Memory>::drain() noexcept {
    if (queue_->closed()) {
      discard();
      return true;
    }

    while (pending()) {
      const auto count = nextSize();
      const auto* data = overflow_.empty() ? inline_.data() : overflow_.data();
      if (!queue_->tryPush({data + consumed_ + header_bytes, count})) {
        return false;
      }

      consumed_ += header_bytes + count;
    }

    discard();
    return true;
  }

  template <Allocator Memory>
  void ResponseOutbox<Memory>::discard() noexcept {
    size_ = 0;
    consumed_ = 0;
    Vector<std::uint8_t, Memory>{overflow_.get_allocator()}.swap(overflow_);
    if (priority_) {
      queue_->releaseWorkerPriority();
      priority_ = false;
    }
  }

  template <Allocator Memory>
  bool ResponseOutbox<Memory>::pending() const noexcept {
    return consumed_ != size_;
  }

  template <Allocator Memory>
  std::size_t ResponseOutbox<Memory>::nextSize() const noexcept {
    if (!pending()) {
      return 0;
    }

    const auto* data = overflow_.empty() ? inline_.data() : overflow_.data();
    std::uint16_t length;

    std::memcpy(&length, data + consumed_, header_bytes);
    assert(length <= size_ - consumed_ - header_bytes);
    return length;
  }

  TextSearch::TextSearch(const SearchPane& request, std::uint64_t revision)
      : TextSearch(request.request_id, request.pane_id, request.needle, {}, revision) {}

  TextSearch::TextSearch(const SearchPaneRows& request, std::uint64_t revision)
      : TextSearch(request.request_id, request.pane_id, request.needle, {.first = request.first_row, .last = request.last_row}, revision) {}

  bool TextSearch::advance(GhosttyTerminal terminal, std::uint64_t revision) {
    if (revision != revision_) {
      throw EncodingError{"Pane changed during search"};
    }

    if (needle_length_ == 0) {
      return true;
    }

    if (!started_) {
      next_row_ = totalRows(terminal);
      checkGhostty(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLS, &columns_));
      next_row_ = std::min<std::size_t>(next_row_, static_cast<std::size_t>(rows_.last) + 1);
      first_row_ = std::max<std::size_t>(rows_.first, next_row_ > maximum_rows ? next_row_ - maximum_rows : 0);
      truncated_ = first_row_ > rows_.first;
      first_row_ = std::min(first_row_, next_row_);
      started_ = true;
    }

    if (Clock::now() >= deadline_) {
      truncated_ = true;
      return true;
    }

    for (std::size_t turn = 0; turn < rows_per_turn && next_row_ > first_row_; ++turn) {
      if (!searchRow(terminal, static_cast<std::uint32_t>(--next_row_))) {
        return true;
      }
    }

    return next_row_ == first_row_;
  }

  PaneMatches TextSearch::result() {
    std::reverse(matches_.begin(), matches_.begin() + count_);
    return PaneMatches{.request_id = request_id, .pane_id = pane_id, .truncated = truncated_, .matches = std::span<const PaneMatch>{matches_}.first(count_)};
  }

  TextSearch::TextSearch(std::uint64_t request, std::uint64_t pane, std::string_view needle, Rows rows, std::uint64_t revision)
      : request_id(request),
        pane_id(pane),
        rows_(rows),
        revision_(revision),
        deadline_(Clock::now() + deadline_budget) {
    if (needle.size() > needle_.size()) {
      throw EncodingError{"Search needle exceeds the wire limit"};
    }

    validateUtf8(needle);
    auto text = needle;

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

  std::uint32_t TextSearch::normalize(std::uint32_t codepoint) const noexcept {
    return fold_ascii_ && codepoint >= 'A' && codepoint <= 'Z' ? codepoint + ('a' - 'A') : codepoint;
  }

  bool TextSearch::searchRow(GhosttyTerminal terminal, std::uint32_t row) {
    auto reference = gridReference(terminal, GHOSTTY_POINT_TAG_SCREEN, {0, row});
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

        found[found_count++] = PaneMatch{.x = start, .y = row, .len = static_cast<std::uint16_t>(column - start + 1)};
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

  template class ResponseOutbox<telar::ConcurrentMemory>;
  template class ResponseOutbox<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>;

}
