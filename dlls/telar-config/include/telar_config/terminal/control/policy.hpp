#pragma once

#include <array>
#include <cstdint>

namespace telar::runtime::control {

enum class Access : std::uint8_t {
  deny,
  ask,
  allow
};

enum class ColorFormat : std::uint8_t {
  none,
  eight_bit,
  sixteen_bit
};

struct Policy {
  Access clipboard_read = Access::ask;
  Access clipboard_write = Access::allow;
  ColorFormat color_format = ColorFormat::sixteen_bit;
  bool title_report = false;
  bool checksum_report = false;
  std::array<char, 1024> answerback{};
  std::uint16_t answerback_length = 0;
};

}
