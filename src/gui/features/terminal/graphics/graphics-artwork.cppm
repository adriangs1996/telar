// An image scaled to the size it is drawn at, for the artwork telar draws itself.
export module telar.gui.features.terminal.graphics:artwork;

import std;
import telar.base.ds;

// Interface: graphics/artwork_resize.cppm
export {
  namespace telar::gui::features::terminal::graphics {

    struct RgbaImageView {
      static constexpr std::size_t channels = 4;
      static constexpr auto maximum_extent = std::numeric_limits<std::uint16_t>::max();

      std::span<const std::byte> pixels;
      std::size_t stride = 0;
      std::size_t width = 0;
      std::size_t height = 0;

      [[nodiscard]] bool valid(std::size_t extent_limit = maximum_extent) const noexcept;
      [[nodiscard]] ds::Array<std::uint8_t, channels> pixel(std::size_t x, std::size_t y) const noexcept;
    };

    class ArtworkResize {
    public:
      static constexpr std::size_t color_channels = 3;
      static constexpr std::uint32_t channel_maximum = 255;

      [[nodiscard]] static bool square(RgbaImageView source, std::span<std::uint8_t> destination, std::size_t side) noexcept;
      [[nodiscard]] static bool rectangle(RgbaImageView source, std::span<std::uint8_t> destination, std::size_t width, std::size_t height) noexcept;
      static void premultiply(std::span<std::uint8_t> pixels) noexcept;

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

        [[nodiscard]] float weight(std::size_t index) const noexcept;
        [[nodiscard]] static Span of(std::size_t index, Axis axis) noexcept;
      };

      struct Tap {
        std::size_t index;
        std::size_t next;
        float fraction;

        [[nodiscard]] static Tap of(std::size_t index, Axis axis) noexcept;
      };

      struct Sample {
        ds::Array<float, color_channels> colors{};
        float alpha = 0;
        float total = 0;

        void add(std::span<const std::uint8_t, RgbaImageView::channels> pixel, float weight) noexcept;
        void write(std::span<std::uint8_t, RgbaImageView::channels> output) const noexcept;
      };

      [[nodiscard]] static Sample areaSample(RgbaImageView source, Span columns, Span rows) noexcept;
      [[nodiscard]] static Sample linearSample(RgbaImageView source, Tap x, Tap y) noexcept;
    };

  }
}
