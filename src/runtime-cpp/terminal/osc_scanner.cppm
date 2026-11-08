module;
#include <cassert>
#include <cstdlib>
#include <new>
#include <ghostty/vt.h>
#include <cstdio>


#include <cstddef>
#include <cstring>
#include <cstdint>


#include "cell_layout.hpp"

export module telar.runtime.terminal.osc_scanner;

import std;

export import telar.base.memory;
import telar.base.diagnostics;
import telar.base.text;
import telar.client.protocol;
import telar.runtime.diagnostics.line;
import telar.runtime.terminal.control;

// Interface: terminal/frame_pacer.cppm
export {
namespace telar::runtime {

class FramePacer {
public:
  using Clock = std::chrono::steady_clock;
  using Time = Clock::time_point;

  inline void configure(std::chrono::nanoseconds interval) noexcept {
    interval_ = interval;
  }

  inline void noteInput(Time time) noexcept {
    if (time != last_input_) {
      last_input_ = time;
      input_frames_left_ = input_burst;
    }
  }

  inline std::optional<Time> deadline(Time now) const noexcept {
    const bool input_recent = last_input_ && input_frames_left_ != 0 && now - *last_input_ < input_grace;
    if (available(now) != 0 || input_recent) {
      return std::nullopt;
    }

    return anchor_.value_or(now) + interval_;
  }

  inline void record(Time now, std::optional<Time> scheduled) noexcept {
    const auto credits = available(now);
    if (credits == 0 && !scheduled && input_frames_left_ != 0) {
      --input_frames_left_;
    }

    credits_ = credits == 0 ? 0 : credits - 1;
    anchor_ = scheduled ? *scheduled + interval_ * ((now - *scheduled) / interval_) : now;
  }

private:
  inline unsigned available(Time now) const noexcept {
    if (!anchor_) {
      return idle_burst;
    }

    const auto refill = std::max(Clock::duration::zero(), now - *anchor_) / interval_;
    return static_cast<unsigned>(std::min<std::int64_t>(idle_burst, credits_ + refill));
  }

  static constexpr unsigned idle_burst = 4;
  static constexpr unsigned input_burst = 16;
  static constexpr auto input_grace = std::chrono::milliseconds{30};
  std::chrono::nanoseconds interval_{1'000'000'000 / 60};
  std::optional<Time> anchor_;
  std::optional<Time> last_input_;
  unsigned credits_ = idle_burst;
  unsigned input_frames_left_ = 0;
};

}
}

// Interface: terminal/input_scanner.cppm
export {
namespace telar::runtime {

enum class ControlByte : std::uint8_t {
  cancel = 0x03,
  bell = 0x07,
  backspace = 0x08,
  newline = 0x0a,
  clear_screen = 0x0c,
  carriage_return = 0x0d,
  escape = 0x1b,
  delete_previous = 0x7f,
};

struct InputEvent {
  bool submitted = false;
  bool cancelled = false;
};

class InputScanner {
public:
  inline InputEvent feed(std::span<const std::uint8_t> bytes) noexcept {
    InputEvent event;
    for (const auto byte : bytes) {
      consume(byte, event);
    }

    return event;
  }

  inline void reset() noexcept {
    state_ = State::ground;
    parameter_ = 0;
    has_parameter_ = false;
    typed_length_ = 0;
    typed_exact_ = true;
  }

  inline void clearSensitive() noexcept {
    eraseSensitive(typed_.data(), typed_.size());
    reset();
  }

  inline std::optional<std::string_view> typedText() const noexcept {
    if (!typed_exact_) {
      return std::nullopt;
    }

    return std::string_view{typed_.data(), typed_length_};
  }

private:
  enum class State {
    ground,
    escape,
    csi,
    paste,
    paste_escape,
    paste_csi
  };
  enum class PasteMarker : std::uint16_t {
    begin = 200,
    end = 201
  };
  static constexpr std::size_t maximum_typed_bytes = 255;

  inline void consume(std::uint8_t byte, InputEvent &event) noexcept {
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

  inline void startSequence(State state) noexcept {
    state_ = state;
    parameter_ = 0;
    has_parameter_ = false;
  }

  inline void sequenceByte(std::uint8_t byte, bool pasted) noexcept {
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

  State state_ = State::ground;
  std::uint16_t parameter_ = 0;
  bool has_parameter_ = false;
  std::array<char, maximum_typed_bytes> typed_;
  std::size_t typed_length_ = 0;
  bool typed_exact_ = true;
};

}
}

// Interface: terminal/osc_scanner.cppm
export {
namespace telar::runtime {

class OscScanner {
public:
  enum class Event {
    none,
    start,
    payload,
    end
  };

  inline Event next(std::uint8_t byte) noexcept {
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

private:
  enum class State {
    ground,
    escape,
    osc,
    osc_escape
  };
  State state_ = State::ground;
};

}
}

// Interface: terminal/response_outbox.cppm
export {
namespace telar::runtime {

// One producer owns these staged messages. Queue publication copies complete
// records; a blocked record is never executed or generated a second time.
template <Allocator Memory>
class ResponseOutbox {
public:
  // The outbox shares the queue it fills, so it keeps no borrow of whoever else holds it.
  inline explicit ResponseOutbox(Memory &memory, std::shared_ptr<PtyResponseQueue> queue)
      : overflow_(AllocatorRef<std::uint8_t, Memory>{memory}), queue_(std::move(queue)) {}

  inline ~ResponseOutbox() { discard(); }

  ResponseOutbox(const ResponseOutbox &) = delete;
  ResponseOutbox &operator=(const ResponseOutbox &) = delete;

  inline void append(std::span<const std::uint8_t> response) {
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
      const auto *header = reinterpret_cast<const std::uint8_t *>(&length);
      overflow_.insert(overflow_.end(), header, header + header_bytes);
      overflow_.insert(overflow_.end(), response.begin(), response.end());
    }
    size_ = required;
    if (!priority_) {
      priority_ = queue_->retainWorkerPriority();
    }
  }

  inline bool drain() noexcept {
    if (queue_->closed()) {
      discard();
      return true;
    }
    while (pending()) {
      const auto count = nextSize();
      const auto *data = overflow_.empty() ? inline_.data() : overflow_.data();
      if (!queue_->tryPush({data + consumed_ + header_bytes, count})) {
        return false;
      }
      consumed_ += header_bytes + count;
    }
    discard();
    return true;
  }

  inline void discard() noexcept {
    size_ = 0;
    consumed_ = 0;
    Vector<std::uint8_t, Memory>{overflow_.get_allocator()}.swap(overflow_);
    if (priority_) {
      queue_->releaseWorkerPriority();
      priority_ = false;
    }
  }

  inline bool pending() const noexcept { return consumed_ != size_; }

  inline std::size_t nextSize() const noexcept {
    if (!pending()) {
      return 0;
    }
    const auto *data = overflow_.empty() ? inline_.data() : overflow_.data();
    std::uint16_t length;
    std::memcpy(&length, data + consumed_, header_bytes);
    assert(length <= size_ - consumed_ - header_bytes);
    return length;
  }

private:
  static constexpr std::size_t inline_bytes = 2048;
  static constexpr std::size_t maximum_bytes = PtyResponseQueue::total_byte_capacity;
  static constexpr std::size_t header_bytes = sizeof(std::uint16_t);
  std::array<std::uint8_t, inline_bytes> inline_;
  Vector<std::uint8_t, Memory> overflow_;
  std::shared_ptr<PtyResponseQueue> queue_;
  std::size_t size_ = 0;
  std::size_t consumed_ = 0;
  bool priority_ = false;
};

}
}

// Interface: terminal/text_search.cppm
export {
namespace telar::runtime {

class TextSearch {
public:
  inline explicit TextSearch(const SearchPane &request, std::uint64_t revision)
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

  inline bool advance(GhosttyTerminal terminal, std::uint64_t revision) {
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

  inline PaneMatches result() {
    std::reverse(matches_.begin(), matches_.begin() + count_);
    return PaneMatches{.request_id = request_id,
                       .pane_id = pane_id,
                       .truncated = truncated_,
                       .matches = std::span<const PaneMatch>{matches_}.first(count_)};
  }

  std::uint64_t request_id;
  std::uint64_t pane_id;

private:
  inline std::uint32_t normalize(std::uint32_t codepoint) const noexcept {
    return fold_ascii_ && codepoint >= 'A' && codepoint <= 'Z' ? codepoint + ('a' - 'A') : codepoint;
  }

  inline bool searchRow(GhosttyTerminal terminal, std::uint32_t row) {
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
}
