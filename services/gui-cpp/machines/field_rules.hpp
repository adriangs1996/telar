#pragma once

#include "failure.hpp"
#include "limits.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include <algorithm>
#include <string_view>

namespace telar::gui {

struct MachineFieldRules {
  static void label(std::string_view text) {
    if (text.empty() || text.size() > MachineLimits::label_bytes || !alphanumeric(text.front()) || !std::ranges::all_of(text, [](char byte) {
          return alphanumeric(byte) || byte == '.' || byte == '_' || byte == '-';
        })) {
      throw MachineFailure{MachineError::invalid_label};
    }
  }

  static void destination(std::string_view text) {
    if (text.empty() || text.front() == '-' || std::ranges::any_of(text, [](unsigned char byte) {
          return byte <= ' ' || byte == delete_byte;
        })) {
      throw MachineFailure{MachineError::invalid_destination};
    }
  }

  static void profileDestination(std::string_view text) {
    if (text.size() > MachineLimits::destination_bytes || inspectUtf8(text) != Utf8Validation::valid) {
      throw MachineFailure{MachineError::invalid_destination};
    }

    destination(text);
  }

  static void color(std::string_view text) {
    if (text.empty() || text.size() > MachineLimits::color_bytes) {
      throw MachineFailure{MachineError::invalid_color};
    }

    if (text.front() == '#') {
      constexpr std::size_t rgb_text_bytes = std::string_view{"#RRGGBB"}.size();
      if (text.size() != rgb_text_bytes || !std::ranges::all_of(text.substr(1), [](char byte) {
            return decimal(byte) || (byte >= 'a' && byte <= 'f') || (byte >= 'A' && byte <= 'F');
          })) {
        throw MachineFailure{MachineError::invalid_color};
      }

      return;
    }

    if (!std::ranges::all_of(text, [](char byte) {
          return (byte >= 'a' && byte <= 'z') || decimal(byte) || byte == '-';
        })) {
      throw MachineFailure{MachineError::invalid_color};
    }
  }

  static void program(std::string_view text) {
    if (text.size() < minimum_program_bytes || text.size() > MachineLimits::program_bytes || text.front() != '/' || text.back() == '/' || text.contains("/../") || text.ends_with("/..")) {
      throw MachineFailure{MachineError::invalid_program};
    }

    if (!std::ranges::all_of(text, [](char byte) {
          return alphanumeric(byte) || byte == '/' || byte == '.' || byte == '_' || byte == '+' || byte == '-';
        })) {
      throw MachineFailure{MachineError::invalid_program};
    }
  }

private:
  static constexpr unsigned char delete_byte = 0x7f;
  static constexpr std::size_t minimum_program_bytes = 2;

  static bool decimal(char byte) noexcept {
    return byte >= '0' && byte <= '9';
  }

  static bool alphanumeric(char byte) noexcept {
    return decimal(byte) || (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z');
  }
};

}
