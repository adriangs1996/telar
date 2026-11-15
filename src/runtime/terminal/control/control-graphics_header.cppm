module;
#include "tbc/annotations.hpp"

export module telar.runtime.terminal.control:graphics_header;

import std;

export namespace telar::runtime::control {

  class GraphicsHeader {
  public:
    static std::optional<std::uint32_t> value(std::uint8_t key, std::string_view text) noexcept;

    // Field views borrow this call's scratch buffer. Classification and query
    // validation share framing, while their callbacks decide which values matter.
    // Generic over the caller's field callback, so it stays here.
    template <typename ProcessField>
      requires requires(ProcessField& process) { { process(std::uint8_t{}, std::string_view{}) } noexcept -> std::same_as<bool>; }
    TBC_GENERIC static bool scan(std::string_view header, bool has_payload, ProcessField&& process) noexcept {
      enum class Phase {
        key,
        ignored_key,
        value,
        ignored_value,
        data,
      };

      Phase phase = Phase::key;
      std::uint8_t key = 0;
      std::array<char, maximum_field_bytes> temporary;
      std::size_t length = 0;
      const auto finish = [&]() {
        const bool accepted = process(key, std::string_view{temporary.data(), length});

        length = 0;
        return accepted;
      };

      const auto accumulate = [&](char byte, Phase overflow) {
        if (length == temporary.size()) {
          phase = overflow;
          length = 0;
        } else {
          temporary[length++] = byte;
        }
      };

      for (std::size_t offset = 0; offset < header.size() + (has_payload ? 1 : 0); ++offset) {
        const char byte = offset == header.size() ? ';' : header[offset];

        switch (phase) {
        case Phase::key:
          if (byte == '=') {
            phase = length == 1 ? Phase::value : Phase::ignored_value;
            if (length == 1) {
              key = static_cast<std::uint8_t>(temporary.front());
            }

            length = 0;
          } else if (byte == ';') {
            phase = Phase::data;
          } else {
            accumulate(byte, Phase::ignored_key);
          }

          break;
        case Phase::ignored_key:
          if (byte == '=') {
            phase = Phase::ignored_value;
          }

          break;
        case Phase::value:
          if (byte == ',' || byte == ';') {
            if (!finish()) {
              return false;
            }

            phase = byte == ',' ? Phase::key : Phase::data;
          } else {
            accumulate(byte, Phase::ignored_value);
          }

          break;
        case Phase::ignored_value:
          if (byte == ',') {
            phase = Phase::ignored_key;
          } else if (byte == ';') {
            phase = Phase::data;
          }

          break;
        case Phase::data:
          break;
        }
      }

      return phase != Phase::key && phase != Phase::ignored_key && (phase != Phase::value || finish());
    }

  private:
    static constexpr std::size_t maximum_field_bytes = 11;
  };

}
