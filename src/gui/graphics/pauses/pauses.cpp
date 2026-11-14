module telar.gui.graphics.pauses;

import std;

import telar.wire.vocabulary;

namespace telar::gui {

  template <typename Result>
  Result GraphicsPauses::PaneCall<Result>::operator()(std::uint64_t pane_id) const {
    return call(context, pane_id);
  }

  bool RgbaImageView::valid(std::size_t extent_limit) const noexcept {
    if (width == 0 || height == 0 || stride == 0 || width > extent_limit || height > extent_limit) {
      return false;
    }

    if (width > stride / channels || height - 1 > pixels.size() / stride) {
      return false;
    }

    const auto last_row = (height - 1) * stride;

    return width * channels <= pixels.size() - last_row;
  }

  std::array<std::uint8_t, RgbaImageView::channels> RgbaImageView::pixel(std::size_t x, std::size_t y) const noexcept {
    const auto source = pixels.subspan((y * stride) + (x * channels)).first<channels>();

    return {std::to_integer<std::uint8_t>(source[0]), std::to_integer<std::uint8_t>(source[1]), std::to_integer<std::uint8_t>(source[2]), std::to_integer<std::uint8_t>(source[3])};
  }

  bool ArtworkResize::square(RgbaImageView source, std::span<std::uint8_t> destination, std::size_t side) noexcept {
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

  bool ArtworkResize::rectangle(RgbaImageView source, std::span<std::uint8_t> destination, std::size_t width, std::size_t height) noexcept {
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

  void ArtworkResize::premultiply(std::span<std::uint8_t> pixels) noexcept {
    constexpr auto half_channel = channel_maximum / 2;

    for (std::size_t offset = 0; offset + RgbaImageView::channels <= pixels.size(); offset += RgbaImageView::channels) {
      const auto alpha = pixels[offset + color_channels];

      for (std::size_t channel = 0; channel < color_channels; ++channel) {
        pixels[offset + channel] = static_cast<std::uint8_t>(((static_cast<std::uint32_t>(pixels[offset + channel]) * alpha) + half_channel) / channel_maximum);
      }
    }
  }

  float ArtworkResize::Span::weight(std::size_t index) const noexcept {
    if (end == first + 1) {
      return lead + trail - 1;
    }

    if (index == first) {
      return lead;
    }

    return index == end - 1 ? trail : 1;
  }

  ArtworkResize::Span ArtworkResize::Span::of(std::size_t index, Axis axis) noexcept {
    const auto start = static_cast<float>(index) * axis.scale;
    const auto stop = std::min(static_cast<float>(axis.extent), start + axis.scale);
    const auto first = static_cast<std::size_t>(std::floor(start));
    const auto end = std::min(axis.extent, static_cast<std::size_t>(std::ceil(stop)));

    return {.first = first, .end = end, .lead = static_cast<float>(first + 1) - start, .trail = stop - static_cast<float>(end - 1)};
  }

  ArtworkResize::Tap ArtworkResize::Tap::of(std::size_t index, Axis axis) noexcept {
    constexpr float pixel_center = 0.5F;
    const auto center = std::max(0.0F, ((static_cast<float>(index) + pixel_center) * axis.scale) - pixel_center);
    const auto first = std::min(axis.extent - 1, static_cast<std::size_t>(std::floor(center)));

    return {.index = first, .next = std::min(axis.extent - 1, first + 1), .fraction = std::min(1.0F, center - static_cast<float>(first))};
  }

  void ArtworkResize::Sample::add(std::span<const std::uint8_t, RgbaImageView::channels> pixel, float weight) noexcept {
    const auto contribution = static_cast<float>(pixel[color_channels]) * weight;

    alpha += contribution;
    total += weight;
    for (std::size_t channel = 0; channel < colors.size(); ++channel) {
      colors[channel] += static_cast<float>(pixel[channel]) * contribution;
    }
  }

  void ArtworkResize::Sample::write(std::span<std::uint8_t, RgbaImageView::channels> output) const noexcept {
    std::ranges::fill(output, 0);
    if (alpha <= 0 || total <= 0) {
      return;
    }

    output[color_channels] = static_cast<std::uint8_t>(std::min(static_cast<float>(channel_maximum), std::round(alpha / total)));
    for (std::size_t channel = 0; channel < colors.size(); ++channel) {
      output[channel] = static_cast<std::uint8_t>(std::min(static_cast<float>(channel_maximum), std::round(colors[channel] / alpha)));
    }
  }

  ArtworkResize::Sample ArtworkResize::areaSample(RgbaImageView source, Span columns, Span rows) noexcept {
    Sample sample;

    for (auto row = rows.first; row < rows.end; ++row) {
      const auto row_weight = rows.weight(row);

      for (auto column = columns.first; column < columns.end; ++column) {
        sample.add(source.pixel(column, row), row_weight * columns.weight(column));
      }
    }

    return sample;
  }

  ArtworkResize::Sample ArtworkResize::linearSample(RgbaImageView source, Tap x, Tap y) noexcept {
    Sample sample;

    sample.add(source.pixel(x.index, y.index), (1 - x.fraction) * (1 - y.fraction));
    sample.add(source.pixel(x.next, y.index), x.fraction * (1 - y.fraction));
    sample.add(source.pixel(x.index, y.next), (1 - x.fraction) * y.fraction);
    sample.add(source.pixel(x.next, y.next), x.fraction * y.fraction);
    sample.total = 1;

    return sample;
  }

  bool GraphicsPauses::contains(std::uint64_t pane_id) const noexcept {
    const auto slot = find(pane_id);

    return slot && !rows_[*slot].resumed_ns;
  }

  std::span<const GraphicsPauses::Row> GraphicsPauses::rows() const noexcept {
    return std::span{rows_}.first(count_);
  }

  std::uint64_t GraphicsPauses::revision() const noexcept {
    return revision_;
  }

  std::optional<std::uint64_t> GraphicsPauses::nextDeadline() const noexcept {
    if (waiting_count_ == 0) {
      return std::nullopt;
    }

    auto earliest = std::numeric_limits<std::uint64_t>::max();

    for (const auto& row : rows()) {
      if (row.waiting) {
        earliest = std::min(earliest, row.due_ns);
      }
    }

    return earliest;
  }

  void GraphicsPauses::pause(std::uint64_t pane_id, std::uint64_t now_ns, PaneCall<void> request, PaneCall<void> notice) {
    auto slot = find(pane_id);
    if (slot) {
      auto& row = rows_[*slot];
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

    auto& row = rows_[*slot];

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

  void GraphicsPauses::resumeDue(std::uint64_t now_ns, PaneCall<void> request) {
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

  void GraphicsPauses::focus(Focus event, PaneCall<void> request) {
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

  void GraphicsPauses::snapshotApplied(std::uint64_t pane_id, SnapshotPhase phase, std::uint64_t now_ns) noexcept {
    const auto slot = find(pane_id);
    if (!slot) {
      return;
    }

    auto& row = rows_[*slot];

    if (phase == SnapshotPhase::begin) {
      row.snapshot_begun = true;
    } else if (row.snapshot_begun) {
      row.snapshot_begun = false;
      row.resumed_ns = now_ns;
      setWaiting(*slot, false);
      ++revision_;
    }
  }

  void GraphicsPauses::forgetClosed(PaneCall<bool> mirrored) {
    for (auto slot = count_; slot-- > 0;) {
      if (!mirrored(rows_[slot].pane_id)) {
        remove(slot);
      }
    }
  }

  void GraphicsPauses::reset() noexcept {
    if (count_ != 0) {
      count_ = 0;
      waiting_count_ = 0;
      ++revision_;
    }
  }

  std::uint64_t GraphicsPauses::elapsed(std::uint64_t now_ns, std::uint64_t since_ns) noexcept {
    return now_ns - std::min(now_ns, since_ns);
  }

  std::uint64_t GraphicsPauses::deadlineAfter(std::uint64_t now_ns, std::uint64_t duration_ns) noexcept {
    return now_ns + std::min(duration_ns, std::numeric_limits<std::uint64_t>::max() - now_ns);
  }

  void GraphicsPauses::increment(std::uint8_t& value) noexcept {
    if (value != std::numeric_limits<std::uint8_t>::max()) {
      ++value;
    }
  }

  std::optional<std::size_t> GraphicsPauses::find(std::uint64_t pane_id) const noexcept {
    for (std::size_t slot = 0; slot < count_; ++slot) {
      if (rows_[slot].pane_id == pane_id) {
        return slot;
      }
    }

    return std::nullopt;
  }

  std::size_t GraphicsPauses::oldest() const noexcept {
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

  std::size_t GraphicsPauses::start(std::uint64_t pane_id, std::uint64_t now_ns, PaneCall<void> request) {
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

  void GraphicsPauses::remove(std::size_t slot) noexcept {
    setWaiting(slot, false);
    rows_[slot] = rows_[--count_];
    ++revision_;
  }

  void GraphicsPauses::setWaiting(std::size_t slot, bool waiting) noexcept {
    auto& row = rows_[slot];
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

  void GraphicsPauses::resume(std::size_t slot, std::uint64_t now_ns) noexcept {
    auto& row = rows_[slot];

    row.resyncs = 1;
    row.since_ns = now_ns;
    row.snapshot_begun = false;
    setWaiting(slot, false);
  }

}
