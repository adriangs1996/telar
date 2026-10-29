#pragma once

#include "core/geometry.hpp"
#include "core/theme_values.hpp"
#include "mode_hints.hpp"
#include "mode_key_label.hpp"
#include "text/bounded_text.hpp"
#include "text/cell_text_measure.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <span>
#include <stdexcept>
#include <string_view>

namespace telar::gui {

struct ModeBarLabel {
  static constexpr std::size_t text_capacity = 128;
  BoundedText<text_capacity> text;
  Rect bounds;
  PaletteRole ink = PaletteRole::subtext0;
  bool bold = false;
};

struct ModeBarRequest {
  StatusMode mode = StatusMode::normal;
  ModeHints hints{};
  Rect bounds;
  float ratio = 1;
  float cell_width = 1;
};

class ModeBarLayout {
public:
  static constexpr float chip_height = 18;
  static constexpr float chip_radius = 4;
  static constexpr float chip_gap = 8;
  static constexpr float hint_gap = 12;
  static constexpr float key_gap = 4;
  static constexpr std::size_t maximum_labels = 2 + (2 * ModeHints::capacity);
  static constexpr std::string_view copy_help = " h/j/k/l move  v select  V lines  / search  y copy  o open  q exit ";
  static constexpr std::string_view cancel_help = "Esc cancel";

  [[nodiscard]] static ModeBarLayout measure(const ModeBarRequest &request) {
    if (!std::isfinite(request.ratio) || request.ratio <= 0 || !std::isfinite(request.cell_width) || request.cell_width <= 0) {
      throw std::invalid_argument{"InvalidModeBarMetrics"};
    }

    ModeBarLayout result;
    if (request.mode == StatusMode::normal || request.bounds.empty()) {
      return result;
    }

    const auto title = request.mode == StatusMode::copy ? std::string_view{" COPY "} : std::string_view{" PREFIX "};
    const auto height = std::min(request.bounds.height, chip_height * request.ratio);
    const auto title_width = std::min(width(title, request.cell_width), request.bounds.width);
    result.chip_ = {.x = request.bounds.x, .y = request.bounds.y + std::floor((request.bounds.height - height) / 2), .width = title_width, .height = height};
    result.append(title, {.x = request.bounds.x, .y = request.bounds.y, .width = title_width, .height = request.bounds.height}, PaletteRole::surface_dim, true);
    auto x = request.bounds.x + title_width + (chip_gap * request.ratio);
    if (request.mode == StatusMode::copy) {
      static_cast<void>(result.hint(copy_help, x, request));

      return result;
    }

    static_cast<void>(result.hint(cancel_help, x, request));
    x += hint_gap * request.ratio;
    for (const auto &item : request.hints.items()) {
      const auto key = ModeKeyLabel::format(item.key);
      if (!result.hint(key.view(), x, request, true)) {
        break;
      }

      x += key_gap * request.ratio;
      if (!result.hint(item.label, x, request)) {
        break;
      }

      x += hint_gap * request.ratio;
    }

    return result;
  }

  [[nodiscard]] Rect chip() const noexcept {
    return chip_;
  }

  [[nodiscard]] std::span<const ModeBarLabel> labels() const noexcept {
    return std::span{labels_}.first(count_);
  }

private:
  [[nodiscard]] static float width(std::string_view text, float cell_width) {
    return static_cast<float>(cellTextColumns(text)) * cell_width;
  }

  bool hint(std::string_view text, float &x, const ModeBarRequest &request, bool key = false) {
    const auto advance = width(text, request.cell_width);
    if (x + advance > request.bounds.right()) {
      return false;
    }

    append(text, {.x = x, .y = request.bounds.y, .width = advance, .height = request.bounds.height}, key ? PaletteRole::accent : PaletteRole::subtext0, key);
    x += advance;

    return true;
  }

  void append(std::string_view text, Rect bounds, PaletteRole ink, bool bold) {
    auto &label = labels_[count_++];
    label.text.append(text);
    label.bounds = bounds;
    label.ink = ink;
    label.bold = bold;
  }

  Rect chip_;
  std::array<ModeBarLabel, maximum_labels> labels_{};
  std::size_t count_ = 0;
};

}
