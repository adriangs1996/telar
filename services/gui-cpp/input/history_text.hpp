#pragma once

#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include <cstddef>
#include <string_view>

namespace telar::gui {

class HistoryText {
public:
  static constexpr std::size_t maximum_bytes = std::size_t{64} * 1024;

  static void validate(std::string_view text, bool bracketed_paste) {
    if (text.empty() || text.size() > maximum_bytes) {
      throw EncodingError{"Command is empty or exceeds its input capacity"};
    }

    validateUtf8(text);
    for (std::size_t index = 0; index < text.size(); ++index) {
      const auto byte = static_cast<Byte>(text[index]);
      if (byte == '\n' || byte == '\t') {
        if (!bracketed_paste) {
          throw EncodingError{"Multiline/tab paste requires shell bracketed-paste support"};
        }

        continue;
      }

      if (isControl(text, index)) {
        throw EncodingError{"Command contains terminal controls; cannot paste"};
      }
    }
  }

private:
  static bool isControl(std::string_view text, std::size_t index) noexcept {
    constexpr Byte first_printable = 0x20;
    constexpr Byte delete_control = 0x7f;
    constexpr Byte extended_control_lead = 0xc2;
    constexpr Byte first_extended_control = 0x80;
    constexpr Byte last_extended_control = 0x9f;
    const auto byte = static_cast<Byte>(text[index]);
    if (byte < first_printable || byte == delete_control) {
      return true;
    }

    if (byte != extended_control_lead || index + 1 == text.size()) {
      return false;
    }

    const auto next = static_cast<Byte>(text[index + 1]);

    return next >= first_extended_control && next <= last_extended_control;
  }
};

}
