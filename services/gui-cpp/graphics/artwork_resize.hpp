#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <span>

namespace telar::gui {

struct RgbaImageView {
  static constexpr std::size_t channels = 4;
  static constexpr auto maximum_extent = std::numeric_limits<std::uint16_t>::max();

  std::span<const std::byte> pixels;
  std::size_t stride = 0;
  std::size_t width = 0;
  std::size_t height = 0;

  [[nodiscard]] bool valid(std::size_t extent_limit = maximum_extent) const noexcept {
    if (width == 0 || height == 0 || stride == 0 || width > extent_limit || height > extent_limit) {
      return false;
    }

    if (width > stride / channels || height - 1 > pixels.size() / stride) {
      return false;
    }

    const auto last_row = (height - 1) * stride;

    return width * channels <= pixels.size() - last_row;
  }

  [[nodiscard]] std::array<std::uint8_t, channels> pixel(std::size_t x, std::size_t y) const noexcept {
    const auto source = pixels.subspan((y * stride) + (x * channels)).first<channels>();
    return {std::to_integer<std::uint8_t>(source[0]), std::to_integer<std::uint8_t>(source[1]), std::to_integer<std::uint8_t>(source[2]), std::to_integer<std::uint8_t>(source[3])};
  }
};

class ArtworkResize {
public:
  static constexpr std::size_t color_channels = 3;
  static constexpr std::uint32_t channel_maximum = 255;

  [[nodiscard]] static bool square(RgbaImageView source, std::span<std::uint8_t> destination, std::size_t side) noexcept {
    if (!source.valid() || side == 0 || side > RgbaImageView::maximum_extent) {
      return false;
    }

    if (side > std::numeric_limits<std::size_t>::max() / RgbaImageView::channels / side || destination.size() != side * side * RgbaImageView::channels) {
      return false;
    }

    const Axis horizontal{.extent = source.width, .scale = static_cast<float>(source.width) / static_cast<float>(side)};
    const Axis vertical{.extent = source.height, .scale = static_cast<float>(source.height) / static_cast<float>(side)};

    for (std::size_t row = 0; row < side; ++row) {
      for (std::size_t column = 0; column < side; ++column) {
        const auto output = destination.subspan(((row * side) + column) * RgbaImageView::channels).first<RgbaImageView::channels>();
        const auto sample = source.width >= side && source.height >= side ? areaSample(source, Span::of(column, horizontal), Span::of(row, vertical)) : linearSample(source, Tap::of(column, horizontal), Tap::of(row, vertical));
        sample.write(output);
      }
    }

    return true;
  }

  [[nodiscard]] static bool rectangle(RgbaImageView source, std::span<std::uint8_t> destination, std::size_t width, std::size_t height) noexcept {
    if (!source.valid(std::numeric_limits<std::uint32_t>::max()) || width == 0 || height == 0 || width > RgbaImageView::maximum_extent || height > RgbaImageView::maximum_extent) {
      return false;
    }

    if (width > std::numeric_limits<std::size_t>::max() / RgbaImageView::channels / height || destination.size() != width * height * RgbaImageView::channels) {
      return false;
    }

    const Axis horizontal{.extent = source.width, .scale = static_cast<float>(source.width) / static_cast<float>(width)};
    const Axis vertical{.extent = source.height, .scale = static_cast<float>(source.height) / static_cast<float>(height)};
    for (std::size_t row = 0; row < height; ++row) {
      const auto rows = Span::of(row, vertical);
      for (std::size_t column = 0; column < width; ++column) {
        const auto output = destination.subspan(((row * width) + column) * RgbaImageView::channels).first<RgbaImageView::channels>();
        areaSample(source, Span::of(column, horizontal), rows).write(output);
      }
    }

    return true;
  }

  static void premultiply(std::span<std::uint8_t> pixels) noexcept {
    constexpr auto half_channel = channel_maximum / 2;
    for (std::size_t offset = 0; offset + RgbaImageView::channels <= pixels.size(); offset += RgbaImageView::channels) {
      const auto alpha = pixels[offset + color_channels];
      for (std::size_t channel = 0; channel < color_channels; ++channel) {
        pixels[offset + channel] = static_cast<std::uint8_t>(((static_cast<std::uint32_t>(pixels[offset + channel]) * alpha) + half_channel) / channel_maximum);
      }
    }
  }

private:
  struct Axis {
    std::size_t extent;
    float scale;
  };

  struct Span {
    std::size_t first;
    std::size_t end;
    float lead;
    float trail;

    [[nodiscard]] float weight(std::size_t index) const noexcept {
      if (end == first + 1) {
        return lead + trail - 1;
      }

      if (index == first) {
        return lead;
      }

      return index == end - 1 ? trail : 1;
    }

    [[nodiscard]] static Span of(std::size_t index, Axis axis) noexcept {
      const auto start = static_cast<float>(index) * axis.scale;
      const auto stop = std::min(static_cast<float>(axis.extent), start + axis.scale);
      const auto first = static_cast<std::size_t>(std::floor(start));
      const auto end = std::min(axis.extent, static_cast<std::size_t>(std::ceil(stop)));

      return {.first = first, .end = end, .lead = static_cast<float>(first + 1) - start, .trail = stop - static_cast<float>(end - 1)};
    }
  };

  struct Tap {
    std::size_t index;
    std::size_t next;
    float fraction;

    [[nodiscard]] static Tap of(std::size_t index, Axis axis) noexcept {
      constexpr float pixel_center = 0.5F;
      const auto center = std::max(0.0F, ((static_cast<float>(index) + pixel_center) * axis.scale) - pixel_center);
      const auto first = std::min(axis.extent - 1, static_cast<std::size_t>(std::floor(center)));

      return {.index = first, .next = std::min(axis.extent - 1, first + 1), .fraction = std::min(1.0F, center - static_cast<float>(first))};
    }
  };

  struct Sample {
    std::array<float, color_channels> colors{};
    float alpha = 0;
    float total = 0;

    void add(std::span<const std::uint8_t, RgbaImageView::channels> pixel, float weight) noexcept {
      const auto contribution = static_cast<float>(pixel[color_channels]) * weight;
      alpha += contribution;
      total += weight;
      for (std::size_t channel = 0; channel < colors.size(); ++channel) {
        colors[channel] += static_cast<float>(pixel[channel]) * contribution;
      }
    }

    void write(std::span<std::uint8_t, RgbaImageView::channels> output) const noexcept {
      std::ranges::fill(output, 0);
      if (alpha <= 0 || total <= 0) {
        return;
      }

      output[color_channels] = static_cast<std::uint8_t>(std::min(static_cast<float>(channel_maximum), std::round(alpha / total)));
      for (std::size_t channel = 0; channel < colors.size(); ++channel) {
        output[channel] = static_cast<std::uint8_t>(std::min(static_cast<float>(channel_maximum), std::round(colors[channel] / alpha)));
      }
    }
  };

  [[nodiscard]] static Sample areaSample(RgbaImageView source, Span columns, Span rows) noexcept {
    Sample sample;
    for (auto row = rows.first; row < rows.end; ++row) {
      const auto row_weight = rows.weight(row);
      for (auto column = columns.first; column < columns.end; ++column) {
        sample.add(source.pixel(column, row), row_weight * columns.weight(column));
      }
    }

    return sample;
  }

  [[nodiscard]] static Sample linearSample(RgbaImageView source, Tap x, Tap y) noexcept {
    Sample sample;
    sample.add(source.pixel(x.index, y.index), (1 - x.fraction) * (1 - y.fraction));
    sample.add(source.pixel(x.next, y.index), x.fraction * (1 - y.fraction));
    sample.add(source.pixel(x.index, y.next), (1 - x.fraction) * y.fraction);
    sample.add(source.pixel(x.next, y.next), x.fraction * y.fraction);
    sample.total = 1;

    return sample;
  }
};

}
