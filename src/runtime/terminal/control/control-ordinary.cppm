export module telar.runtime.terminal.control:ordinary;

import std;

// The scans of ordinary output, which vt_state.cpp compiles for the target's 16-byte vectors and
// as plain byte loops. VtState::writeOrdinaryRun, in that unit, runs the vector ones; the scalar
// ones are what a target without those vectors runs, exported for the tests.
export namespace telar::runtime::control {

  namespace styled_detail {

    enum class Control : std::uint8_t {
      enquiry = 0x05,
      escape = 0x1b,
    };
    inline constexpr auto enquiry = static_cast<std::uint8_t>(Control::enquiry);
    inline constexpr auto escape = static_cast<std::uint8_t>(Control::escape);
    inline constexpr std::size_t vector_bytes = 16;

    constexpr bool numericSgrByte(std::uint8_t byte) noexcept {
      const auto relative = static_cast<unsigned>(byte) - static_cast<unsigned>('0');

      return relative <= static_cast<unsigned>(';' - '0') && byte != ':';
    }

    // The instructions a scan compiles to: the target's 16-byte compares, or one byte at a time.
    enum class Isa : std::uint8_t {
      scalar,
      vector,
    };

    // Finds the next ESC or ENQ, keeping the last vector's matches for the offsets inside it.
    template <Isa Set>
    class ControlScanner {
    public:
      explicit ControlScanner(std::span<const std::uint8_t> input) noexcept;

      std::size_t next(std::size_t offset) noexcept;

    private:
      std::span<const std::uint8_t> input_;
      std::uint64_t matches_ = 0;
      std::size_t window_begin_ = 0;
      std::size_t window_end_ = 0;
    };

    extern template class ControlScanner<Isa::scalar>;
    extern template class ControlScanner<Isa::vector>;

  }

  // Search from the supplied offset, crossing only complete bounded numeric SGRs.
  // Every other ESC and every ENQ remains a native controller boundary.
  std::size_t styledOrdinaryLength(std::span<const std::uint8_t> input, std::size_t prefix) noexcept;
  std::size_t styledOrdinaryLengthScalar(std::span<const std::uint8_t> input, std::size_t prefix) noexcept;

  namespace ascii_detail {

    inline constexpr std::size_t gate_bytes = styled_detail::vector_bytes * 2;
    inline constexpr std::size_t codepoint_capacity = 4096;
    inline constexpr std::uint8_t non_ascii_first = 0x80;

    // Whether the first gate_bytes of the input are ASCII without ESC or ENQ.
    bool eligible(std::span<const std::uint8_t> input) noexcept;
    bool eligibleScalar(std::span<const std::uint8_t> input) noexcept;

    // Complete vector stores may initialize scratch after the accepted prefix,
    // but every read and write stays within both supplied spans.
    std::size_t widen(std::span<const std::uint8_t> input, std::span<std::uint32_t> output) noexcept;
    std::size_t widenScalar(std::span<const std::uint8_t> input, std::span<std::uint32_t> output) noexcept;

  }

}
