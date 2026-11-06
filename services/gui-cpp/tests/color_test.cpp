#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include <bit>
#include <cfenv>
#include <cstdio>
#include <exception>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <type_traits>



import telar.gui.core.metrics;

namespace {

using telar::gui::Color;
using ColorBits = std::array<std::uint32_t, 4>;

constexpr unsigned channel_bits = 8;
constexpr std::uint32_t channel_mask = std::numeric_limits<std::uint8_t>::max();
constexpr std::array<std::uint32_t, 8> alpha_bits{
    0x00000000, 0x80000000, 0x00000001, 0x3f000000,
    0x3f800000, 0x7f800000, 0xff800000, 0x7fc12345,
};
constexpr auto constant_color = Color::rgb(0x123456, 0.5F);
constexpr Color constant_expected{.r = 18.0F / 255.0F, .g = 52.0F / 255.0F, .b = 86.0F / 255.0F, .a = 0.5F};
static_assert(constant_color.r == constant_expected.r && constant_color.g == constant_expected.g && constant_color.b == constant_expected.b && constant_color.a == constant_expected.a);
static_assert(sizeof(Color) == sizeof(ColorBits) && std::is_trivially_copyable_v<Color> && std::is_aggregate_v<Color>);

void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

float referenceChannel(std::uint32_t channel) {
  const volatile auto numerator = static_cast<float>(channel);
  const volatile float denominator = channel_mask;

  return numerator / denominator;
}

void verify(std::uint32_t rgb, std::uint32_t alpha) {
  const ColorBits expected{
      std::bit_cast<std::uint32_t>(referenceChannel((rgb >> (channel_bits * 2)) & channel_mask)),
      std::bit_cast<std::uint32_t>(referenceChannel((rgb >> channel_bits) & channel_mask)),
      std::bit_cast<std::uint32_t>(referenceChannel(rgb & channel_mask)),
      alpha,
  };
  const auto actual = std::bit_cast<ColorBits>(Color::rgb(rgb, std::bit_cast<float>(alpha)));
  require(actual == expected, "RGB normalization must preserve all color and alpha bits");
}

std::size_t everyChannel() {
  constexpr std::uint32_t other_channels = 0xa55aa55a;
  std::size_t checks = 0;
  for (const auto shift : {0U, channel_bits, channel_bits * 2}) {
    for (std::uint32_t channel = 0; channel <= channel_mask; ++channel) {
      const auto rgb = (other_channels & ~(channel_mask << shift)) | (channel << shift);
      for (const auto alpha : alpha_bits) {
        verify(rgb, alpha);
        ++checks;
      }
    }
  }

  return checks;
}

std::size_t combinedChannels() {
  constexpr std::size_t samples = 4096;
  constexpr std::uint32_t multiplier = 1664525;
  constexpr std::uint32_t increment = 1013904223;
  constexpr std::uint32_t seed = 0x4b2719e3;
  auto state = seed;
  for (std::size_t sample = 0; sample < samples; ++sample) {
    state = (state * multiplier) + increment;
    for (const auto alpha : alpha_bits) {
      verify(state, alpha);
    }
  }

  return samples * alpha_bits.size();
}

}

int main() {
  try {
    require(std::fegetround() == FE_TONEAREST, "RGB oracle requires round-to-nearest");
    constexpr std::size_t expected_checks = 38912;
    const auto checks = everyChannel() + combinedChannels();
    require(checks == expected_checks, "RGB oracle must execute every declared case");
    std::puts("gui-color: 38912 bit-exact cases passed");
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
