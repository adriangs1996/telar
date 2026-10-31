// Frozen parser from ab35af576; differential oracle for owned OSC accumulation.
#pragma once

#include "../../memory/allocator.hpp"
#include "../../terminal/control/sequence.hpp"
#include "../../terminal/control/apc_borrow.hpp"
#include <array>
#include <cstring>
#include <utility>

namespace telar::runtime::control {

template <Allocator Memory>
class BaselineOscParser {
public:
  static constexpr std::size_t inline_bytes = 256;
  static constexpr std::size_t header_limit = 8192;
  static constexpr std::size_t dcs_limit = 1024 * 1024 + header_limit;
  static constexpr std::size_t osc_limit = 8 * 1024 * 1024;
  static constexpr std::size_t apc_limit = 65 * 1024 * 1024;
  static constexpr std::size_t string_limit = apc_limit;

  explicit BaselineOscParser(Memory &memory) : overflow_(AllocatorRef<std::uint8_t, Memory>{memory}) {}

  // Consumers borrow a sequence only during complete(). A false result leaves
  // its owned bytes unchanged, including across calls with an empty input.
  template <typename Consumer>
  std::size_t feed(std::span<const std::uint8_t> input, Consumer &consumer) {
    std::size_t consumed = 0;
    std::size_t next_escape = 0;
    bool escape_searched = false;
    while (true) {
      if (phase_ == Phase::ready) {
        if (!consumer.complete(Sequence{kind_, bytes(), ending_})) {
          return consumed;
        }

        clear();
        phase_ = after_ready_;
        if (following_c1_ != 0) {
          const auto control = std::exchange(following_c1_, 0);
          if (!startC1(control)) {
            executeC1(control, consumer);
            phase_ = Phase::ground;
          } else {
            continue;
          }
        } else if (phase_ == Phase::escape) {
          append(escape);
        }
      }

      if (consumed == input.size()) {
        return consumed;
      }

      if (phase_ == Phase::ground && input[consumed] == escape) {
        const auto remaining = input.subspan(consumed);
        if (const auto length = completeCsi(remaining)) {
          beforeEscape(consumer);
          const auto sequence = remaining.first(length);
          consumed += length;
          if (consumer.complete(Sequence{Kind::csi, sequence, Ending::final_byte})) {
            continue;
          }
          // Only a blocked request needs a retained copy. The successful
          // whole-slice path lends input for this synchronous callback.
          clear();
          for (const auto byte : sequence) {
            append(byte);
          }
          kind_ = Kind::csi;
          ending_ = Ending::final_byte;
          after_ready_ = Phase::ground;
          phase_ = Phase::ready;
          return consumed;
        }
      }

      if (phase_ == Phase::ground && input[consumed] != escape && input[consumed] != enquiry) {
        if constexpr (requires { consumer.ordinaryRun(input, consumed); }) {
          consumed = consumer.ordinaryRun(input, consumed);
          continue;
        } else {
          const auto remaining = input.subspan(consumed);
          if (!escape_searched || consumed > next_escape) {
            const auto *found = static_cast<const std::uint8_t *>(std::memchr(remaining.data(), escape, remaining.size()));
            next_escape = found == nullptr ? input.size() : static_cast<std::size_t>(found - input.data());
            escape_searched = true;
          }
          auto count = next_escape - consumed;
          const auto *first_enquiry = static_cast<const std::uint8_t *>(std::memchr(remaining.data(), enquiry, count));
          if (first_enquiry != nullptr) {
            count = static_cast<std::size_t>(first_enquiry - remaining.data());
          }
          if (count != 0) {
            consumer.ordinary(remaining.first(count));
            consumed += count;
            continue;
          }
        }
      }

      const bool string = phase_ == Phase::string || phase_ == Phase::streaming || phase_ == Phase::discard_string;
      if (string) {
        if (!feedString(input, consumed, consumer)) {
          return consumed;
        }
        continue;
      }

      const auto byte = input[consumed];

      if (byte == enquiry) {
        if (!consumer.enquire()) {
          return consumed;
        }
        ++consumed;
        continue;
      }

      ++consumed;
      if (byte == cancel || byte == substitute) {
        clear();
        phase_ = Phase::ground;
        consumer.ordinary(input.subspan(consumed - 1, 1));
        ++cancelled_;
        continue;
      }

      if (byte == escape) {
        beforeEscape(consumer);
        clear();
        append(byte);
        phase_ = Phase::escape;
        continue;
      }

      if (phase_ != Phase::ground && byte >= c1_first && byte <= c1_last) {
        clear();
        if (!startC1(byte)) {
          executeC1(byte, consumer);
          phase_ = Phase::ground;
        }
        continue;
      }

      if (phase_ == Phase::ground) {
        consumer.ordinary(input.subspan(consumed - 1, 1));
        continue;
      }

      if (byte == delete_byte || byte > c1_last) {
        continue;
      }
      if (byte < space) {
        consumer.ordinary(input.subspan(consumed - 1, 1));
        continue;
      }

      if (phase_ == Phase::discard_csi) {
        if (byte >= final_first && byte <= final_last) {
          phase_ = Phase::ground;
          clear();
        }
        continue;
      }

      if (phase_ == Phase::escape && size_ == 1) {
        if (startEscape(byte)) {
          continue;
        }
      }

      if (size_ >= header_limit || !append(byte)) {
        clear();
        phase_ = Phase::discard_csi;
        ++over_limit_;
        continue;
      }

      const bool final = phase_ == Phase::csi ? byte >= final_first && byte <= final_last : byte >= escape_final_first && byte <= final_last;
      if (final) {
        kind_ = phase_ == Phase::csi ? Kind::csi : Kind::escape;
        ending_ = Ending::final_byte;
        after_ready_ = Phase::ground;
        phase_ = Phase::ready;
      }
    }
  }

  bool ground() const noexcept {
    return phase_ == Phase::ground;
  }

  void discard() noexcept {
    Vector<std::uint8_t, Memory>{overflow_.get_allocator()}.swap(overflow_);
    clear();
    phase_ = Phase::ground;
    after_ready_ = Phase::ground;
    string_payload_ = false;
    following_c1_ = 0;
  }

  bool blocked() const noexcept {
    return phase_ == Phase::ready;
  }

  std::uint64_t overLimit() const noexcept {
    return over_limit_;
  }

private:
  enum class Phase : std::uint8_t {
    ground,
    escape,
    csi,
    string,
    streaming,
    discard_csi,
    discard_string,
    ready
  };

  static constexpr std::uint8_t enquiry = 0x05;
  static constexpr std::uint8_t bell = 0x07;
  static constexpr std::uint8_t cancel = 0x18;
  static constexpr std::uint8_t substitute = 0x1a;
  static constexpr std::uint8_t escape = 0x1b;
  static constexpr std::uint8_t space = 0x20;
  static constexpr std::uint8_t escape_final_first = 0x30;
  static constexpr std::uint8_t final_first = 0x40;
  static constexpr std::uint8_t final_last = 0x7e;
  static constexpr std::uint8_t delete_byte = 0x7f;
  static constexpr std::uint8_t c1_first = 0x80;
  static constexpr std::uint8_t c1_last = 0x9f;
  static constexpr std::uint8_t c1_st = 0x9c;
  static constexpr std::uint8_t c1_decid = 0x9a;
  static constexpr std::uint8_t c1_sos = 0x98;
  static constexpr std::uint8_t c1_pm = 0x9e;
  static constexpr std::uint8_t c1_apc = 0x9f;

  template <typename Consumer>
  static bool finishStream(Consumer &consumer) {
    if constexpr (requires { consumer.streamComplete(); }) {
      return consumer.streamComplete();
    }
    return true;
  }

  template <typename Consumer>
  static void beforeEscape(Consumer &consumer) {
    if constexpr (requires { consumer.escapeBoundary(); }) {
      consumer.escapeBoundary();
    }
  }

  template <typename Consumer>
  static void executeC1(std::uint8_t byte, Consumer &consumer) {
    // C1 controls executed inside a control sequence are not UTF-8 text.
    // Preserve that context for the non-query backend using an ESC prefix.
    const std::array<std::uint8_t, 2> control{escape, byte};
    consumer.ordinary(control);
  }

  static std::size_t completeCsi(std::span<const std::uint8_t> input) noexcept {
    if (input.size() < 3 || input[1] != '[') {
      return 0;
    }
    const auto limit = std::min(input.size(), header_limit);
    for (std::size_t index = 2; index < limit; ++index) {
      const auto byte = input[index];
      if (byte >= final_first && byte <= final_last) {
        return index + 1;
      }
      if (byte < space || byte > '?') {
        return 0;
      }
    }
    return 0;
  }

  static std::span<const std::uint8_t> asBytes(std::string_view text) noexcept {
    return {reinterpret_cast<const std::uint8_t *>(text.data()), text.size()};
  }

  template <typename Consumer>
  [[gnu::noinline]] bool feedString(std::span<const std::uint8_t> input, std::size_t &consumed, Consumer &consumer) {
    if constexpr (requires { consumer.borrowableApc(Sequence{}); }) {
      if (input.size() - consumed > inline_bytes && phase_ == Phase::string && kind_ == Kind::apc && size_ == 2 && consumed >= 2 && input[consumed - 2] == escape && input[consumed - 1] == inline_[1]) {
        if (const auto handled = borrowApc(input, consumed, consumer)) {
          return *handled;
        }
      }
    }

    while (consumed < input.size() && (phase_ == Phase::string || phase_ == Phase::streaming || phase_ == Phase::discard_string)) {
      const auto byte = input[consumed];
      if (byte == escape || byte == cancel || byte == substitute || (kind_ == Kind::osc && byte == bell) || (kind_ == Kind::apc && byte == c1_st)) {
        ++consumed;
        if (byte == cancel || byte == substitute) {
          if ((kind_ == Kind::dcs || kind_ == Kind::apc) && phase_ == Phase::string) {
            ending_ = Ending::escape;
            after_ready_ = Phase::ground;
            phase_ = Phase::ready;
            ++cancelled_;
            continue;
          }
          if (phase_ == Phase::streaming) {
            consumer.ordinary(input.subspan(consumed - 1, 1));
          }
          clear();
          phase_ = Phase::ground;
          ++cancelled_;
          if (!finishStream(consumer)) {
            return false;
          }
          continue;
        }

        ending_ = byte == bell ? Ending::bell : byte == c1_st ? Ending::c1 : Ending::escape;
        after_ready_ = byte == escape ? Phase::escape : Phase::ground;
        if (phase_ == Phase::streaming) {
          const auto terminator = ending_ == Ending::bell ? std::string_view{"\a"} : std::string_view{"\x1b\\"};
          consumer.ordinary(asBytes(terminator));
          clear();
          phase_ = after_ready_;
          if (phase_ == Phase::escape) {
            append(escape);
          }
          if (!finishStream(consumer)) {
            return false;
          }
        } else if (phase_ == Phase::discard_string) {
          clear();
          phase_ = after_ready_;
          if (phase_ == Phase::escape) {
            append(escape);
          }
        } else {
          phase_ = Phase::ready;
        }
        continue;
      }

      if ((kind_ == Kind::apc || (kind_ == Kind::dcs && !string_payload_)) && byte >= c1_first && byte <= c1_last) {
        // Same-kind string introducers have no exit/entry action in APC.
        if (kind_ == Kind::apc && (byte == c1_sos || byte == c1_pm || byte == c1_apc)) {
          ++consumed;
          continue;
        }
        if (kind_ == Kind::apc && phase_ == Phase::string) {
          ending_ = Ending::escape;
          after_ready_ = Phase::ground;
          following_c1_ = byte;
          phase_ = Phase::ready;
          ++consumed;
          continue;
        }
        const bool streamed = phase_ == Phase::streaming;
        if (streamed) {
          consumer.ordinary(asBytes("\x18"));
        }
        clear();
        phase_ = Phase::escape;
        ++cancelled_;
        if (!startC1(byte)) {
          executeC1(byte, consumer);
          phase_ = Phase::ground;
        }
        ++consumed;
        if (streamed && !finishStream(consumer)) {
          return false;
        }
        continue;
      }

      if (phase_ == Phase::streaming) {
        std::size_t end = consumed + 1;
        while (end < input.size() && !stringControl(input[end])) {
          ++end;
        }
        consumer.ordinary(input.subspan(consumed, end - consumed));
        consumed = end;
        continue;
      }

      ++consumed;
      if (phase_ == Phase::discard_string) {
        continue;
      }

      // OSC ignores C0 throughout its body; DCS ignores them only before
      // the final header byte. Normalize before classification so ignored
      // controls cannot disguise a native query as a backend operation.
      if (byte < space && (kind_ == Kind::osc || (kind_ == Kind::dcs && !string_payload_))) {
        continue;
      }
      if (kind_ == Kind::dcs && byte == delete_byte) {
        continue;
      }
      if (byte > c1_last && (kind_ == Kind::apc || (kind_ == Kind::dcs && !string_payload_))) {
        continue;
      }
      const auto limit = kind_ == Kind::osc ? osc_limit : kind_ == Kind::dcs ? dcs_limit : apc_limit;
      if (size_ == limit || !append(byte)) {
        phase_ = Phase::discard_string;
        ++over_limit_;
        continue;
      }

      const bool header_complete = !string_payload_ && (kind_ == Kind::dcs ? byte >= final_first && byte <= final_last : byte == ';');
      if (header_complete) {
        string_payload_ = true;
        if (consumer.streamable(Sequence{kind_, bytes(), Ending::final_byte})) {
          consumer.ordinary(bytes());
          clear();
          phase_ = Phase::streaming;
        }
      }
      continue;
    }

    return true;
  }

  // Successful delivery borrows the caller's input only during complete(). A
  // blocked delivery retains a bounded copy before any input can be released.
  template <typename Consumer>
  std::optional<bool> borrowApc(std::span<const std::uint8_t> input, std::size_t &consumed, Consumer &consumer) {
    const auto start = consumed - 2;
    const auto remaining = input.subspan(start);
    if (remaining[2] != 'G') {
      return std::nullopt;
    }
    const auto length = completeAsciiApc(remaining, apc_limit);
    if (length <= inline_bytes) {
      return std::nullopt;
    }

    const auto sequence = remaining.first(length);
    const auto *separator = static_cast<const std::uint8_t *>(std::memchr(sequence.data(), ';', sequence.size()));
    if (separator == nullptr || !consumer.borrowableApc(Sequence{Kind::apc, sequence.first(separator + 1 - sequence.data()), Ending::final_byte})) {
      return std::nullopt;
    }

    const bool delivered = consumer.complete(Sequence{Kind::apc, sequence, Ending::escape});
    clear();
    consumed = start + length + 1;
    ending_ = Ending::escape;
    after_ready_ = Phase::escape;
    if (delivered) {
      append(escape);
      phase_ = Phase::escape;
    } else {
      overflow_.assign(sequence.begin(), sequence.end());
      size_ = sequence.size();
      phase_ = Phase::ready;
    }
    return delivered;
  }

  bool stringControl(std::uint8_t byte) const noexcept {
    return byte == escape || byte == cancel || byte == substitute || (kind_ == Kind::osc && byte == bell) || (kind_ == Kind::apc && byte >= c1_first && byte <= c1_last);
  }

  bool startEscape(std::uint8_t byte) {
    switch (byte) {
    case '[':
      kind_ = Kind::csi;
      phase_ = Phase::csi;
      break;
    case ']':
      kind_ = Kind::osc;
      phase_ = Phase::string;
      break;
    case 'P':
      kind_ = Kind::dcs;
      phase_ = Phase::string;
      break;
    case '_':
    case '^':
    case 'X':
      kind_ = Kind::apc;
      phase_ = Phase::string;
      break;
    default:
      return false;
    }

    string_payload_ = false;
    append(byte);
    return true;
  }

  bool startC1(std::uint8_t byte) {
    if (byte == c1_decid) {
      append(escape);
      append('Z');
      kind_ = Kind::escape;
      ending_ = Ending::final_byte;
      after_ready_ = Phase::ground;
      phase_ = Phase::ready;
      return true;
    }
    char introducer = 0;
    switch (byte) {
    case 0x90: introducer = 'P'; break;
    case 0x98: introducer = 'X'; break;
    case 0x9b: introducer = '['; break;
    case 0x9d: introducer = ']'; break;
    case 0x9e: introducer = '^'; break;
    case 0x9f: introducer = '_'; break;
    default: return false;
    }

    append(escape);
    return startEscape(static_cast<std::uint8_t>(introducer));
  }

  std::span<const std::uint8_t> bytes() const noexcept {
    return overflow_.empty() ? std::span<const std::uint8_t>{inline_}.first(size_) : std::span<const std::uint8_t>{overflow_};
  }

  bool append(std::uint8_t byte) {
    if (size_ == string_limit) {
      return false;
    }

    if (size_ < inline_.size()) {
      inline_[size_++] = byte;
      return true;
    }

    if (overflow_.empty()) {
      overflow_.reserve(inline_.size() * 2);
      overflow_.insert(overflow_.end(), inline_.begin(), inline_.end());
    }

    if (overflow_.size() == overflow_.capacity()) {
      overflow_.reserve(std::min(string_limit, overflow_.capacity() * 2));
    }
    overflow_.push_back(byte);
    ++size_;
    return true;
  }

  void clear() noexcept {
    size_ = 0;
    overflow_.clear();
  }

  std::array<std::uint8_t, inline_bytes> inline_;
  Vector<std::uint8_t, Memory> overflow_;
  std::size_t size_ = 0;
  Phase phase_ = Phase::ground;
  Phase after_ready_ = Phase::ground;
  Kind kind_ = Kind::escape;
  Ending ending_ = Ending::final_byte;
  bool string_payload_ = false;
  std::uint8_t following_c1_ = 0;
  std::uint64_t cancelled_ = 0;
  std::uint64_t over_limit_ = 0;
};

}
