module;
#include "tbc/annotations.hpp"

export module telar.runtime.terminal.control:parser;

import std;
import telar.base.memory.allocators;
import :sequence;
import telar.base.ds;

export namespace telar::runtime::control {

  // Only a complete unchanged printable APC may borrow input. Other bytes use
  // the incremental parser, preserving cancellation and C1 normalization.
  std::size_t completeAsciiApc(std::span<const std::uint8_t> input, std::size_t limit) noexcept;

  // Generic over the caller's allocator and consumer, so it stays here.
  template <Allocator Memory>
  class TBC_GENERIC Parser {
  public:
    static constexpr std::size_t inline_bytes = 256;
    static constexpr std::size_t header_limit = 8192;
    static constexpr std::size_t dcs_limit = (std::size_t{1024} * 1024) + header_limit;
    static constexpr std::size_t osc_limit = std::size_t{8} * 1024 * 1024;
    static constexpr std::size_t apc_limit = std::size_t{65} * 1024 * 1024;
    static constexpr std::size_t string_limit = apc_limit;

    explicit Parser(Memory& memory)
        : overflow_(memory) {}

    // Consumers borrow a sequence only during complete(). A false result leaves
    // its owned bytes unchanged, including across calls with an empty input.
    template <typename Consumer>
    std::size_t feed(std::span<const std::uint8_t> input, Consumer& consumer) {
      std::size_t consumed = 0;
      EscapeSearch search;

      // Each stage's step is tested right where it returns, so that the inlined stages jump
      // straight to the loop or out of it.
      while (true) {
        const auto ready = deliverReady(consumer);
        if (ready == Step::stop) {
          return consumed;
        }

        if (ready == Step::next) {
          continue;
        }

        if (consumed == input.size()) {
          return consumed;
        }

        const auto ground = groundRun(input, consumed, consumer, search);
        if (ground == Step::stop) {
          return consumed;
        }

        if (ground == Step::next) {
          continue;
        }

        if (sequenceInput(input, consumed, consumer) == Step::stop) {
          return consumed;
        }
      }
    }

    [[nodiscard]] bool ground() const noexcept {
      return phase_ == Phase::ground;
    }

    void discard() noexcept {
      overflow_ = ds::Vec<std::uint8_t, Memory>{overflow_.memory()};
      clear();
      phase_ = Phase::ground;
      after_ready_ = Phase::ground;
      string_payload_ = false;
      following_c1_ = 0;
    }

    [[nodiscard]] bool blocked() const noexcept {
      return phase_ == Phase::ready;
    }

    [[nodiscard]] std::uint64_t overLimit() const noexcept {
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
      ready,
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
    static constexpr std::uint8_t c1_dcs = 0x90;
    static constexpr std::uint8_t c1_sos = 0x98;
    static constexpr std::uint8_t c1_decid = 0x9a;
    static constexpr std::uint8_t c1_csi = 0x9b;
    static constexpr std::uint8_t c1_st = 0x9c;
    static constexpr std::uint8_t c1_osc = 0x9d;
    static constexpr std::uint8_t c1_pm = 0x9e;
    static constexpr std::uint8_t c1_apc = 0x9f;

    // What a stage of feed() leaves its loop to do: go on to the next stage, take the next turn,
    // or return what it consumed.
    enum class Step : std::uint8_t {
      proceed,
      next,
      stop,
    };

    // Where the next ESC of the input lies, once a run of ordinary bytes has looked for it.
    struct EscapeSearch {
      std::size_t next = 0;
      bool searched = false;
    };

    // Delivers a complete sequence, then resumes the phase that its terminator began.
    template <typename Consumer>
    [[gnu::always_inline]] Step deliverReady(Consumer& consumer) {
      if (phase_ != Phase::ready) {
        return Step::proceed;
      }

      if (!consumer.complete(Sequence{kind_, bytes(), ending_})) {
        return Step::stop;
      }

      clear();
      phase_ = after_ready_;
      if (following_c1_ != 0) {
        const auto control = std::exchange(following_c1_, 0);
        if (startC1(control)) {
          return Step::next;
        }

        executeC1(control, consumer);
        phase_ = Phase::ground;
      } else if (phase_ == Phase::escape) {
        append(escape);
      }

      return Step::proceed;
    }

    // In ground, a complete CSI is lent to the consumer whole and ordinary bytes go out in runs.
    template <typename Consumer>
    [[gnu::always_inline]] Step groundRun(std::span<const std::uint8_t> input, std::size_t& consumed, Consumer& consumer, EscapeSearch& search) {
      if (phase_ != Phase::ground) {
        return Step::proceed;
      }

      const auto byte = input[consumed];
      if (byte == escape) {
        return wholeCsi(input, consumed, consumer);
      }

      if (byte == enquiry) {
        return Step::proceed;
      }

      return ordinaryRun(input, consumed, consumer, search);
    }

    template <typename Consumer>
    [[gnu::always_inline]] Step wholeCsi(std::span<const std::uint8_t> input, std::size_t& consumed, Consumer& consumer) {
      const auto remaining = input.subspan(consumed);
      const auto length = completeCsi(remaining);
      if (length == 0) {
        return Step::proceed;
      }

      beforeEscape(consumer);
      const auto sequence = remaining.first(length);

      consumed += length;
      if (consumer.complete(Sequence{.kind = Kind::csi, .bytes = sequence, .ending = Ending::final_byte})) {
        return Step::next;
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
      return Step::stop;
    }

    template <typename Consumer>
    [[gnu::always_inline]] static Step ordinaryRun(std::span<const std::uint8_t> input, std::size_t& consumed, Consumer& consumer, EscapeSearch& search) {
      if constexpr (requires { consumer.ordinaryRun(input, consumed); }) {
        consumed = consumer.ordinaryRun(input, consumed);
        return Step::next;
      } else {
        const auto remaining = input.subspan(consumed);

        if (!search.searched || consumed > search.next) {
          const auto* found = static_cast<const std::uint8_t*>(std::memchr(remaining.data(), escape, remaining.size()));

          search.next = found == nullptr ? input.size() : static_cast<std::size_t>(found - input.data());
          search.searched = true;
        }

        auto count = search.next - consumed;
        const auto* first_enquiry = static_cast<const std::uint8_t*>(std::memchr(remaining.data(), enquiry, count));
        if (first_enquiry != nullptr) {
          count = static_cast<std::size_t>(first_enquiry - remaining.data());
        }

        if (count == 0) {
          return Step::proceed;
        }

        consumer.ordinary(remaining.first(count));
        consumed += count;
        return Step::next;
      }
    }

    // A string's body goes to feedString; any other byte steps the escape and CSI machine.
    template <typename Consumer>
    [[gnu::always_inline]] Step sequenceInput(std::span<const std::uint8_t> input, std::size_t& consumed, Consumer& consumer) {
      if (stringPhase()) {
        return feedString(input, consumed, consumer) ? Step::next : Step::stop;
      }

      if (input[consumed] == enquiry) {
        if (!consumer.enquire()) {
          return Step::stop;
        }

        ++consumed;
        return Step::next;
      }

      ++consumed;
      controlByte(input.subspan(consumed - 1, 1), consumer);
      return Step::next;
    }

    // One byte outside a string, `current` its view in the input.
    template <typename Consumer>
    [[gnu::always_inline]] void controlByte(std::span<const std::uint8_t> current, Consumer& consumer) {
      const auto byte = current.front();

      if (byte == cancel || byte == substitute) {
        clear();
        phase_ = Phase::ground;
        consumer.ordinary(current);
        ++cancelled_;
        return;
      }

      if (byte == escape) {
        beforeEscape(consumer);
        clear();
        append(byte);
        phase_ = Phase::escape;
        return;
      }

      if (phase_ != Phase::ground && byte >= c1_first && byte <= c1_last) {
        clear();
        if (!startC1(byte)) {
          executeC1(byte, consumer);
          phase_ = Phase::ground;
        }

        return;
      }

      if (phase_ == Phase::ground) {
        consumer.ordinary(current);
        return;
      }

      if (byte == delete_byte || byte > c1_last) {
        return;
      }

      if (byte < space) {
        consumer.ordinary(current);
        return;
      }

      headerByte(byte);
    }

    // A printable byte of an escape or CSI sequence, which its final byte completes.
    [[gnu::always_inline]] void headerByte(std::uint8_t byte) {
      if (phase_ == Phase::discard_csi) {
        if (byte >= final_first && byte <= final_last) {
          phase_ = Phase::ground;
          clear();
        }

        return;
      }

      if (phase_ == Phase::escape && size_ == 1 && startEscape(byte)) {
        return;
      }

      if (size_ >= header_limit || !append(byte)) {
        clear();
        phase_ = Phase::discard_csi;
        ++over_limit_;
        return;
      }

      const bool final = phase_ == Phase::csi ? byte >= final_first && byte <= final_last : byte >= escape_final_first && byte <= final_last;
      if (final) {
        kind_ = phase_ == Phase::csi ? Kind::csi : Kind::escape;
        ending_ = Ending::final_byte;
        after_ready_ = Phase::ground;
        phase_ = Phase::ready;
      }
    }

    [[nodiscard]] bool stringPhase() const noexcept {
      return phase_ == Phase::string || phase_ == Phase::streaming || phase_ == Phase::discard_string;
    }

    template <typename Consumer>
    static bool finishStream(Consumer& consumer) {
      if constexpr (requires { consumer.streamComplete(); }) {
        return consumer.streamComplete();
      }

      return true;
    }

    template <typename Consumer>
    static void beforeEscape(Consumer& consumer) {
      if constexpr (requires { consumer.escapeBoundary(); }) {
        consumer.escapeBoundary();
      }
    }

    template <typename Consumer>
    static void executeC1(std::uint8_t byte, Consumer& consumer) {
      // C1 controls executed inside a control sequence are not UTF-8 text.
      // Preserve that context for the non-query backend using an ESC prefix.
      const ds::Array<std::uint8_t, 2> control{escape, byte};

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

    template <typename Consumer>
    [[gnu::noinline]] bool feedString(std::span<const std::uint8_t> input, std::size_t& consumed, Consumer& consumer) {
      if constexpr (requires { consumer.borrowableApc(Sequence{}); }) {
        if (apcBorrowable(input, consumed)) {
          if (const auto handled = borrowApc(input, consumed, consumer)) {
            return *handled;
          }
        }
      }

      if (phase_ == Phase::string && kind_ == Kind::osc && string_payload_) {
        appendOscRun(input, consumed);
      }

      while (consumed < input.size() && stringPhase()) {
        const auto byte = input[consumed];
        if (endsString(byte)) {
          if (!stringEnd(input, consumed, consumer, byte)) {
            return false;
          }

          continue;
        }

        if (cancelsString(byte)) {
          if (!stringC1(consumed, consumer, byte)) {
            return false;
          }

          continue;
        }

        if (phase_ == Phase::streaming) {
          streamRun(input, consumed, consumer);
          continue;
        }

        ++consumed;
        stringByte(input, consumed, consumer, byte);
      }

      return true;
    }

    static std::span<const std::uint8_t> asBytes(std::string_view text) noexcept {
      return {reinterpret_cast<const std::uint8_t*>(text.data()), text.size()}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the bytes may alias char, and no cast-free view reads text as bytes
    }

    [[nodiscard]] bool apcBorrowable(std::span<const std::uint8_t> input, std::size_t consumed) const noexcept {
      return input.size() - consumed > inline_bytes && phase_ == Phase::string && kind_ == Kind::apc && size_ == 2 && consumed >= 2 && input[consumed - 2] == escape && input[consumed - 1] == inline_[1];
    }

    // ESC, BEL in OSC and ST in APC end a string; CAN and SUB cancel it.
    [[nodiscard]] bool endsString(std::uint8_t byte) const noexcept {
      return byte == escape || byte == cancel || byte == substitute || (kind_ == Kind::osc && byte == bell) || (kind_ == Kind::apc && byte == c1_st);
    }

    // A C1 control cancels an APC, and a DCS before its final header byte.
    [[nodiscard]] bool cancelsString(std::uint8_t byte) const noexcept {
      return (kind_ == Kind::apc || (kind_ == Kind::dcs && !string_payload_)) && byte >= c1_first && byte <= c1_last;
    }

    static Ending stringEnding(std::uint8_t byte) noexcept {
      if (byte == bell) {
        return Ending::bell;
      }

      return byte == c1_st ? Ending::c1 : Ending::escape;
    }

    [[nodiscard]] std::size_t stringLimit() const noexcept {
      if (kind_ == Kind::osc) {
        return osc_limit;
      }

      return kind_ == Kind::dcs ? dcs_limit : apc_limit;
    }

    // The byte that ends or cancels a string. False when the consumer holds a stream's end.
    template <typename Consumer>
    [[gnu::always_inline]] bool stringEnd(std::span<const std::uint8_t> input, std::size_t& consumed, Consumer& consumer, std::uint8_t byte) {
      ++consumed;
      if (byte == cancel || byte == substitute) {
        return cancelString(input.subspan(consumed - 1, 1), consumer);
      }

      ending_ = stringEnding(byte);
      after_ready_ = byte == escape ? Phase::escape : Phase::ground;
      if (phase_ == Phase::streaming) {
        const auto terminator = ending_ == Ending::bell ? std::string_view{"\a"} : std::string_view{"\x1b\\"};

        consumer.ordinary(asBytes(terminator));
        resumeAfterString();
        return finishStream(consumer);
      }

      if (phase_ == Phase::discard_string) {
        resumeAfterString();
        return true;
      }

      phase_ = Phase::ready;
      return true;
    }

    // CAN or SUB, `current` its view in the input.
    template <typename Consumer>
    [[gnu::always_inline]] bool cancelString(std::span<const std::uint8_t> current, Consumer& consumer) {
      if ((kind_ == Kind::dcs || kind_ == Kind::apc) && phase_ == Phase::string) {
        ending_ = Ending::escape;
        after_ready_ = Phase::ground;
        phase_ = Phase::ready;
        ++cancelled_;
        return true;
      }

      if (phase_ == Phase::streaming) {
        consumer.ordinary(current);
      }

      clear();
      phase_ = Phase::ground;
      ++cancelled_;
      return finishStream(consumer);
    }

    void resumeAfterString() {
      clear();
      phase_ = after_ready_;
      if (phase_ == Phase::escape) {
        append(escape);
      }
    }

    // A C1 control inside an APC, or a DCS header.
    template <typename Consumer>
    [[gnu::always_inline]] bool stringC1(std::size_t& consumed, Consumer& consumer, std::uint8_t byte) {
      // Same-kind string introducers have no exit/entry action in APC.
      if (kind_ == Kind::apc && (byte == c1_sos || byte == c1_pm || byte == c1_apc)) {
        ++consumed;
        return true;
      }

      if (kind_ == Kind::apc && phase_ == Phase::string) {
        ending_ = Ending::escape;
        after_ready_ = Phase::ground;
        following_c1_ = byte;
        phase_ = Phase::ready;
        ++consumed;
        return true;
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
      return !streamed || finishStream(consumer);
    }

    // A streamed string's bytes go out in runs up to its next control.
    template <typename Consumer>
    [[gnu::always_inline]] void streamRun(std::span<const std::uint8_t> input, std::size_t& consumed, Consumer& consumer) {
      std::size_t end = consumed + 1;

      while (end < input.size() && !stringControl(input[end])) {
        ++end;
      }

      consumer.ordinary(input.subspan(consumed, end - consumed));
      consumed = end;
    }

    // A byte of a retained string, `consumed` already past it.
    template <typename Consumer>
    [[gnu::always_inline]] void stringByte(std::span<const std::uint8_t> input, std::size_t& consumed, Consumer& consumer, std::uint8_t byte) {
      if (phase_ == Phase::discard_string) {
        return;
      }

      // OSC ignores C0 throughout its body; DCS ignores them only before
      // the final header byte. Normalize before classification so ignored
      // controls cannot disguise a native query as a backend operation.
      if (byte < space && (kind_ == Kind::osc || (kind_ == Kind::dcs && !string_payload_))) {
        return;
      }

      if (kind_ == Kind::dcs && byte == delete_byte) {
        return;
      }

      if (byte > c1_last && (kind_ == Kind::apc || (kind_ == Kind::dcs && !string_payload_))) {
        return;
      }

      if (size_ == stringLimit() || !append(byte)) {
        phase_ = Phase::discard_string;
        ++over_limit_;
        return;
      }

      const bool header_complete = !string_payload_ && (kind_ == Kind::dcs ? byte >= final_first && byte <= final_last : byte == ';');
      if (!header_complete) {
        return;
      }

      string_payload_ = true;
      if (consumer.streamable(Sequence{kind_, bytes(), Ending::final_byte})) {
        consumer.ordinary(bytes());
        clear();
        phase_ = Phase::streaming;
      } else if (kind_ == Kind::osc) {
        appendOscRun(input, consumed);
      }
    }

    // Successful delivery borrows the caller's input only during complete(). A
    // blocked delivery retains a bounded copy before any input can be released.
    template <typename Consumer>
    ds::Option<bool> borrowApc(std::span<const std::uint8_t> input, std::size_t& consumed, Consumer& consumer) {
      const auto start = consumed - 2;
      const auto remaining = input.subspan(start);
      if (remaining[2] != 'G') {
        return ds::none;
      }

      const auto length = completeAsciiApc(remaining, apc_limit);
      if (length <= inline_bytes) {
        return ds::none;
      }

      const auto sequence = remaining.first(length);
      const auto* separator = static_cast<const std::uint8_t*>(std::memchr(sequence.data(), ';', sequence.size()));
      if (separator == nullptr || !consumer.borrowableApc(Sequence{.kind = Kind::apc, .bytes = sequence.first(separator + 1 - sequence.data()), .ending = Ending::final_byte})) {
        return ds::none;
      }

      const bool delivered = consumer.complete(Sequence{.kind = Kind::apc, .bytes = sequence, .ending = Ending::escape});

      clear();
      consumed = start + length + 1;
      ending_ = Ending::escape;
      after_ready_ = Phase::escape;
      if (delivered) {
        append(escape);
        phase_ = Phase::escape;
      } else {
        overflow_.clear();
        overflow_.extend({sequence.begin(), sequence.end()});
        size_ = sequence.size();
        phase_ = Phase::ready;
      }

      return delivered;
    }

    [[nodiscard]] bool stringControl(std::uint8_t byte) const noexcept {
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
      case c1_dcs:
        introducer = 'P';
        break;
      case c1_sos:
        introducer = 'X';
        break;
      case c1_csi:
        introducer = '[';
        break;
      case c1_osc:
        introducer = ']';
        break;
      case c1_pm:
        introducer = '^';
        break;
      case c1_apc:
        introducer = '_';
        break;
      default:
        return false;
      }

      append(escape);
      return startEscape(static_cast<std::uint8_t>(introducer));
    }

    [[nodiscard]] std::span<const std::uint8_t> bytes() const noexcept {
      return overflow_.empty() ? std::span<const std::uint8_t>{inline_}.first(size_) : std::span<const std::uint8_t>{overflow_};
    }

    // OSC retains every non-C0 byte, including DEL and raw C1. Classify the
    // header first and leave controls and limit overflow to the scalar machine.
    void appendOscRun(std::span<const std::uint8_t> input, std::size_t& consumed) {
      constexpr std::size_t minimum_run_bytes = 8;
      const auto available = std::min(input.size() - consumed, osc_limit - size_);
      if (available < minimum_run_bytes) {
        return;
      }

      std::size_t length = 0;

      while (length < available && input[consumed + length] >= space) {
        ++length;
      }

      appendRun(input.subspan(consumed, length));
      consumed += length;
    }

    // Copy only up to the next existing capacity boundary. Keeping append's
    // reserve schedule also preserves the retained prefix if allocation fails.
    void appendRun(std::span<const std::uint8_t> input) {
      while (!input.empty()) {
        if (size_ < inline_.size()) {
          const auto count = std::min(input.size(), inline_.size() - size_);

          std::memcpy(inline_.dataMut() + size_, input.data(), count);
          size_ += count;
          input = input.subspan(count);
          continue;
        }

        if (overflow_.empty()) {
          overflow_.reserve(inline_.size() * 2);
          overflow_.extend({inline_.begin(), inline_.end()});
        }

        if (overflow_.size() == overflow_.capacity()) {
          overflow_.reserve(std::min(string_limit, overflow_.capacity() * 2));
        }

        const auto count = std::min(input.size(), overflow_.capacity() - overflow_.size());

        overflow_.extend({input.begin(), input.begin() + count});
        size_ += count;
        input = input.subspan(count);
      }
    }

    bool append(std::uint8_t byte) {
      if (size_ == string_limit) {
        return false;
      }

      if (size_ < inline_.size()) {
        inline_.atMut(size_++) = byte;
        return true;
      }

      if (overflow_.empty()) {
        overflow_.reserve(inline_.size() * 2);
        overflow_.extend({inline_.begin(), inline_.end()});
      }

      if (overflow_.size() == overflow_.capacity()) {
        overflow_.reserve(std::min(string_limit, overflow_.capacity() * 2));
      }

      overflow_.push(byte);
      ++size_;
      return true;
    }

    void clear() noexcept {
      size_ = 0;
      overflow_.clear();
    }

    ds::Array<std::uint8_t, inline_bytes> inline_{};
    ds::Vec<std::uint8_t, Memory> overflow_;
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
