export module telar.runtime.terminal.control:graphics_header;

import std;
import telar.base.ds;

export namespace telar::runtime::control {

  class GraphicsHeader {
  public:
    static ds::Option<std::uint32_t> value(std::uint8_t key, std::string_view text) noexcept;

    // Field views borrow this call's scratch buffer. Classification and query
    // validation share framing, while their callbacks decide which values matter.
    // Generic over the caller's field callback, so it stays here.
    template <typename ProcessField>
      requires requires(ProcessField& process) { { process(std::uint8_t{}, std::string_view{}) } noexcept -> std::same_as<bool>; }
    [[tbc::generic]] static bool scan(std::string_view header, bool has_payload, ProcessField&& process) noexcept {
      ScanState state;
      const auto finish = [&] {
        const bool accepted = std::forward<ProcessField>(process)(state.key, state.field());

        state.length = 0;
        return accepted;
      };

      for (std::size_t offset = 0; offset < header.size() + (has_payload ? 1 : 0); ++offset) {
        const char byte = offset == header.size() ? ';' : header[offset];

        if (state.phase == ScanPhase::value && (byte == ',' || byte == ';')) {
          if (!finish()) {
            return false;
          }

          state.phase = byte == ',' ? ScanPhase::key : ScanPhase::data;
          continue;
        }

        state.step(byte);
      }

      return state.phase != ScanPhase::key && state.phase != ScanPhase::ignored_key && (state.phase != ScanPhase::value || finish());
    }

  private:
    static constexpr std::size_t maximum_field_bytes = 11;

    enum class ScanPhase : std::uint8_t {
      key,
      ignored_key,
      value,
      ignored_value,
      data,
    };

    // Where scan() is in a header, and the field it is reading.
    struct ScanState {
      ScanPhase phase = ScanPhase::key;
      std::uint8_t key = 0;
      ds::Array<char, maximum_field_bytes> temporary{};
      std::size_t length = 0;

      [[nodiscard]] constexpr std::string_view field() const noexcept {
        return std::string_view{temporary.view().first(length)};
      }

      // Keeps a byte of the field, or ignores the field once it outgrows the buffer.
      constexpr void accumulate(char byte, ScanPhase overflow) noexcept {
        if (length == temporary.size()) {
          phase = overflow;
          length = 0;
        } else {
          temporary.atMut(length++) = byte;
        }
      }

      // Every byte but the one that ends a value's field, which scan() hands to its caller.
      constexpr void step(char byte) noexcept {
        switch (phase) {
        case ScanPhase::key:
          keyByte(byte);
          break;
        case ScanPhase::ignored_key:
          if (byte == '=') {
            phase = ScanPhase::ignored_value;
          }

          break;
        case ScanPhase::value:
          accumulate(byte, ScanPhase::ignored_value);
          break;
        case ScanPhase::ignored_value:
          if (byte == ',') {
            phase = ScanPhase::ignored_key;
          } else if (byte == ';') {
            phase = ScanPhase::data;
          }

          break;
        case ScanPhase::data:
          break;
        }
      }

      constexpr void keyByte(char byte) noexcept {
        if (byte == '=') {
          phase = length == 1 ? ScanPhase::value : ScanPhase::ignored_value;
          if (length == 1) {
            key = static_cast<std::uint8_t>(temporary.front());
          }

          length = 0;
        } else if (byte == ';') {
          phase = ScanPhase::data;
        } else {
          accumulate(byte, ScanPhase::ignored_key);
        }
      }
    };
  };

}
