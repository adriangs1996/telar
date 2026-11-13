module;
#include <cstring>
#include <cstdio>

#include <cmath>
#include <cstddef>
#include <cstdint>


export module telar.gui.graphics.pauses;

import std;

export import telar.gui.application.sound_playback;
import telar.base.diagnostics;
import telar.client.protocol;

// Interface: graphics/artwork_resize.cppm
export {
namespace telar::gui {

struct RgbaImageView {
  static constexpr std::size_t channels = 4;
  static constexpr auto maximum_extent = std::numeric_limits<std::uint16_t>::max();

  std::span<const std::byte> pixels;
  std::size_t stride = 0;
  std::size_t width = 0;
  std::size_t height = 0;

  [[nodiscard]] inline bool valid(std::size_t extent_limit = maximum_extent) const noexcept {
    if (width == 0 || height == 0 || stride == 0 || width > extent_limit || height > extent_limit) {
      return false;
    }

    if (width > stride / channels || height - 1 > pixels.size() / stride) {
      return false;
    }

    const auto last_row = (height - 1) * stride;

    return width * channels <= pixels.size() - last_row;
  }

  [[nodiscard]] inline std::array<std::uint8_t, channels> pixel(std::size_t x, std::size_t y) const noexcept {
    const auto source = pixels.subspan((y * stride) + (x * channels)).first<channels>();
    return {std::to_integer<std::uint8_t>(source[0]), std::to_integer<std::uint8_t>(source[1]), std::to_integer<std::uint8_t>(source[2]), std::to_integer<std::uint8_t>(source[3])};
  }
};

class ArtworkResize {
public:
  static constexpr std::size_t color_channels = 3;
  static constexpr std::uint32_t channel_maximum = 255;

  [[nodiscard]] inline static bool square(RgbaImageView source, std::span<std::uint8_t> destination, std::size_t side) noexcept {
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

  [[nodiscard]] inline static bool rectangle(RgbaImageView source, std::span<std::uint8_t> destination, std::size_t width, std::size_t height) noexcept {
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

  inline static void premultiply(std::span<std::uint8_t> pixels) noexcept {
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

    [[nodiscard]] inline float weight(std::size_t index) const noexcept {
      if (end == first + 1) {
        return lead + trail - 1;
      }

      if (index == first) {
        return lead;
      }

      return index == end - 1 ? trail : 1;
    }

    [[nodiscard]] inline static Span of(std::size_t index, Axis axis) noexcept {
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

    [[nodiscard]] inline static Tap of(std::size_t index, Axis axis) noexcept {
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

    inline void add(std::span<const std::uint8_t, RgbaImageView::channels> pixel, float weight) noexcept {
      const auto contribution = static_cast<float>(pixel[color_channels]) * weight;
      alpha += contribution;
      total += weight;
      for (std::size_t channel = 0; channel < colors.size(); ++channel) {
        colors[channel] += static_cast<float>(pixel[channel]) * contribution;
      }
    }

    inline void write(std::span<std::uint8_t, RgbaImageView::channels> output) const noexcept {
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

  [[nodiscard]] inline static Sample areaSample(RgbaImageView source, Span columns, Span rows) noexcept {
    Sample sample;
    for (auto row = rows.first; row < rows.end; ++row) {
      const auto row_weight = rows.weight(row);
      for (auto column = columns.first; column < columns.end; ++column) {
        sample.add(source.pixel(column, row), row_weight * columns.weight(column));
      }
    }

    return sample;
  }

  [[nodiscard]] inline static Sample linearSample(RgbaImageView source, Tap x, Tap y) noexcept {
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
}

// Interface: graphics/pauses.cppm
export {
namespace telar::gui {

class GraphicsPauses {
public:
  static constexpr std::size_t capacity = PaneLayout::maximum_panes;
  static constexpr std::uint64_t healthy_window_ns = 60'000'000'000;
  static constexpr std::uint8_t requests_per_window = 3;
  static constexpr std::uint8_t maximum_doublings = 4;

  struct Focus {
    std::uint64_t pane_id = 0;
    std::uint64_t now_ns = 0;
  };

  struct Row {
    std::uint64_t pane_id = 0;
    std::uint64_t since_ns = 0;
    std::uint64_t due_ns = 0;
    std::optional<std::uint64_t> resumed_ns = std::nullopt;
    std::uint8_t resyncs = 0;
    std::uint8_t backoff = 0;
    bool waiting = false;
    bool snapshot_begun = false;
  };

  [[nodiscard]] inline bool contains(std::uint64_t pane_id) const noexcept {
    const auto slot = find(pane_id);

    return slot && !rows_[*slot].resumed_ns;
  }

  [[nodiscard]] inline std::span<const Row> rows() const noexcept {
    return std::span{rows_}.first(count_);
  }

  [[nodiscard]] inline std::uint64_t revision() const noexcept {
    return revision_;
  }

  [[nodiscard]] inline std::optional<std::uint64_t> nextDeadline() const noexcept {
    if (waiting_count_ == 0) {
      return std::nullopt;
    }

    auto earliest = std::numeric_limits<std::uint64_t>::max();
    for (const auto &row : rows()) {
      if (row.waiting) {
        earliest = std::min(earliest, row.due_ns);
      }
    }

    return earliest;
  }

  template <typename Request, typename Notice>
    requires std::invocable<const Request &, std::uint64_t> && std::invocable<const Notice &, std::uint64_t>
  void pause(std::uint64_t pane_id, std::uint64_t now_ns, const Request &request, const Notice &notice) {
    auto slot = find(pane_id);
    if (slot) {
      auto &row = rows_[*slot];
      if (row.resumed_ns) {
        const auto resumed = *row.resumed_ns;
        row.resumed_ns.reset();
        ++revision_;
        if (elapsed(now_ns, resumed) >= healthy_window_ns) {
          remove(*slot);
          slot.reset();
        }
      }
    }

    if (!slot) {
      slot = start(pane_id, now_ns, request);
      notice(pane_id);
    }

    auto &row = rows_[*slot];
    row.snapshot_begun = false;
    if (row.waiting) {
      return;
    }

    if (elapsed(now_ns, row.since_ns) >= healthy_window_ns) {
      row.resyncs = 0;
      row.since_ns = now_ns;
    }

    increment(row.resyncs);
    if (row.resyncs > requests_per_window) {
      row.due_ns = deadlineAfter(row.since_ns, healthy_window_ns << std::min(row.backoff, maximum_doublings));
      increment(row.backoff);
      setWaiting(*slot, true);
    } else {
      request(pane_id);
    }
  }

  template <typename Request>
    requires std::invocable<const Request &, std::uint64_t>
  void resumeDue(std::uint64_t now_ns, const Request &request) {
    if (waiting_count_ == 0) {
      return;
    }

    for (std::size_t slot = 0; slot < count_; ++slot) {
      if (rows_[slot].waiting && now_ns >= rows_[slot].due_ns) {
        resume(slot, now_ns);
        request(rows_[slot].pane_id);
      }
    }
  }

  template <typename Request>
    requires std::invocable<const Request &, std::uint64_t>
  void focus(Focus event, const Request &request) {
    const auto [pane_id, now_ns] = event;
    if (waiting_count_ == 0) {
      return;
    }

    const auto slot = find(pane_id);
    if (slot && rows_[*slot].waiting && elapsed(now_ns, rows_[*slot].since_ns) >= healthy_window_ns) {
      resume(*slot, now_ns);
      request(pane_id);
    }
  }

  inline void snapshotApplied(std::uint64_t pane_id, SnapshotPhase phase, std::uint64_t now_ns) noexcept {
    const auto slot = find(pane_id);
    if (!slot) {
      return;
    }

    auto &row = rows_[*slot];
    if (phase == SnapshotPhase::begin) {
      row.snapshot_begun = true;
    } else if (row.snapshot_begun) {
      row.snapshot_begun = false;
      row.resumed_ns = now_ns;
      setWaiting(*slot, false);
      ++revision_;
    }
  }

  template <typename Mirrored>
    requires std::predicate<const Mirrored &, std::uint64_t>
  void forgetClosed(const Mirrored &mirrored) {
    for (auto slot = count_; slot-- > 0;) {
      if (!mirrored(rows_[slot].pane_id)) {
        remove(slot);
      }
    }
  }

  inline void reset() noexcept {
    if (count_ != 0) {
      count_ = 0;
      waiting_count_ = 0;
      ++revision_;
    }
  }

private:
  [[nodiscard]] inline static std::uint64_t elapsed(std::uint64_t now_ns, std::uint64_t since_ns) noexcept {
    return now_ns - std::min(now_ns, since_ns);
  }

  [[nodiscard]] inline static std::uint64_t deadlineAfter(std::uint64_t now_ns, std::uint64_t duration_ns) noexcept {
    return now_ns + std::min(duration_ns, std::numeric_limits<std::uint64_t>::max() - now_ns);
  }

  inline static void increment(std::uint8_t &value) noexcept {
    if (value != std::numeric_limits<std::uint8_t>::max()) {
      ++value;
    }
  }

  [[nodiscard]] inline std::optional<std::size_t> find(std::uint64_t pane_id) const noexcept {
    for (std::size_t slot = 0; slot < count_; ++slot) {
      if (rows_[slot].pane_id == pane_id) {
        return slot;
      }
    }

    return std::nullopt;
  }

  [[nodiscard]] inline std::size_t oldest() const noexcept {
    std::size_t found = 0;
    for (std::size_t slot = 1; slot < count_; ++slot) {
      const bool resumed = rows_[slot].resumed_ns.has_value();
      const bool current_resumed = rows_[found].resumed_ns.has_value();
      if ((resumed && !current_resumed) || (resumed == current_resumed && rows_[slot].since_ns < rows_[found].since_ns)) {
        found = slot;
      }
    }

    return found;
  }

  template <typename Request>
    requires std::invocable<const Request &, std::uint64_t>
  std::size_t start(std::uint64_t pane_id, std::uint64_t now_ns, const Request &request) {
    if (count_ == capacity) {
      const auto slot = oldest();
      const auto evicted = rows_[slot];
      remove(slot);
      if (evicted.waiting) {
        request(evicted.pane_id);
      }
    }

    const auto slot = count_++;
    rows_[slot] = {.pane_id = pane_id, .since_ns = now_ns, .due_ns = now_ns};
    ++revision_;

    return slot;
  }

  inline void remove(std::size_t slot) noexcept {
    setWaiting(slot, false);
    rows_[slot] = rows_[--count_];
    ++revision_;
  }

  inline void setWaiting(std::size_t slot, bool waiting) noexcept {
    auto &row = rows_[slot];
    if (row.waiting != waiting) {
      row.waiting = waiting;
      if (waiting) {
        ++waiting_count_;
      } else {
        --waiting_count_;
      }

      ++revision_;
    }
  }

  inline void resume(std::size_t slot, std::uint64_t now_ns) noexcept {
    auto &row = rows_[slot];
    row.resyncs = 1;
    row.since_ns = now_ns;
    row.snapshot_begun = false;
    setWaiting(slot, false);
  }

  std::array<Row, capacity> rows_{};
  std::size_t count_ = 0;
  std::size_t waiting_count_ = 0;
  std::uint64_t revision_ = 0;
};

}
}
