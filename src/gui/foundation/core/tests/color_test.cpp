#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cfenv>
#include <cstddef>
#include <cstdint>

import std;
import telar.testing;
import telar.gui.foundation.core;
import telar.base.ds;

namespace {

  using telar::gui::Color;
  using telar::testing::check;
  using ColorBits = telar::ds::Array<std::uint32_t, 4>;

  constexpr unsigned channel_bits = 8;
  constexpr std::uint32_t channel_mask = std::numeric_limits<std::uint8_t>::max();
  constexpr telar::ds::Array<std::uint32_t, 8> alpha_bits{
      0x00000000,
      0x80000000,
      0x00000001,
      0x3f000000,
      0x3f800000,
      0x7f800000,
      0xff800000,
      0x7fc12345,
  };
  constexpr auto constant_color = Color::rgb(0x123456, 0.5F);
  constexpr Color constant_expected{.r = 18.0F / 255.0F, .g = 52.0F / 255.0F, .b = 86.0F / 255.0F, .a = 0.5F};
  static_assert(constant_color.r == constant_expected.r && constant_color.g == constant_expected.g && constant_color.b == constant_expected.b && constant_color.a == constant_expected.a);
  static_assert(sizeof(Color) == sizeof(ColorBits) && std::is_trivially_copyable_v<Color> && std::is_aggregate_v<Color>);

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

    check(actual == expected, "RGB normalization must preserve all color and alpha bits");
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

  // Every channel value and a sample of combined colors, bit for bit against an oracle that
  // rounds to nearest; the count proves the oracle ran every declared case.
  void bitExactNormalization() {
    check(std::fegetround() == FE_TONEAREST, "RGB oracle requires round-to-nearest");
    constexpr std::size_t expected_checks = 38912;
    const auto checks = everyChannel() + combinedChannels();

    check(checks == expected_checks, "RGB oracle must execute every declared case");
  }

  const telar::testing::Case case_bit_exact_normalization{"color.bit_exact_normalization", bitExactNormalization};

  bool near(float actual, float expected) {
    constexpr float tolerance = 0.01F;

    return std::abs(actual - expected) < tolerance;
  }

  // The ratios a screenshot of the top bar measured, against the WCAG formula.
  void contrastMatchesWcag() {
    check(near(telar::gui::contrast(Color::rgb(0x000000), Color::rgb(0xffffff)), 21), "black on white is 21:1");
    check(near(telar::gui::contrast(Color::rgb(0x808080), Color::rgb(0x808080)), 1), "a color on itself is 1:1");
    check(near(telar::gui::contrast(Color::rgb(0x989890), Color::rgb(0x3e3d3b)), 3.74F), "the track's names read 3.74:1 on its well");
    check(near(telar::gui::contrast(Color::rgb(0x3e3d3b), Color::rgb(0x989890)), 3.74F), "the ratio does not depend on the order");
  }

  const telar::testing::Case case_contrast_matches_wcag{"color.contrast_matches_wcag", contrastMatchesWcag};

  void legibleReachesTheRatio() {
    const auto well = Color::rgb(0x3e3d3b);
    const auto subtext = Color::rgb(0x989890);
    const auto lifted = telar::gui::legible(subtext, well, 4.5F);

    check(telar::gui::contrast(lifted, well) >= 4.5F, "a dim ink on a dark ground is lifted to the ratio");
    check(telar::gui::contrast(lifted, well) < 4.6F, "the lift stops near the ratio and keeps the ink's hue");
    check(lifted.r > subtext.r, "on a dark ground the ink moves toward white");

    const auto paper = Color::rgb(0xf5f4f0);
    const auto pale = Color::rgb(0xb0b0a8);
    const auto darkened = telar::gui::legible(pale, paper, 4.5F);

    check(telar::gui::contrast(darkened, paper) >= 4.5F, "a pale ink on a light ground is darkened to the ratio");
    check(darkened.r < pale.r, "on a light ground the ink moves toward black");
    check(telar::gui::legible(Color::rgb(0xffffff), well, 4.5F) == Color::rgb(0xffffff), "an ink that already reads is unchanged");
    check(telar::gui::legible(Color::rgb(0x989890, 0.5F), well, 4.5F).a == 0.5F, "the ink keeps its alpha");
  }

  const telar::testing::Case case_legible_reaches_the_ratio{"color.legible_reaches_the_ratio", legibleReachesTheRatio};

}
