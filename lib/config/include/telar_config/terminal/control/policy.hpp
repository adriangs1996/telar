#pragma once

#include "telar_base/ds/values.hpp"
#include <array>
#include <cstddef>
#include <cstdint>

namespace telar::runtime::control {

  enum class Access : std::uint8_t {
    deny,
    ask,
    allow,
  };

  enum class ColorFormat : std::uint8_t {
    none,
    eight_bit,
    sixteen_bit,
  };

  struct Policy {
    static constexpr std::size_t answerback_capacity = 1024;

    Access clipboard_read = Access::ask;
    Access clipboard_write = Access::allow;
    ColorFormat color_format = ColorFormat::sixteen_bit;
    bool title_report = false;
    bool checksum_report = false;
    ds::Array<char, answerback_capacity> answerback{};
    std::uint16_t answerback_length = 0;
  };

}
