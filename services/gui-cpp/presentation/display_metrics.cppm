module;

#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>


#include <algorithm>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include <cmath>
#include "../core/terminal_size.hpp"
#include <limits>
#include <stdexcept>


#include <concepts>
#include <numbers>


#include "telar_client/serializers/telar_protocol.hpp"


#include <utility>

export module telar.gui.presentation.display_metrics;

export import telar.gui.core.metrics;


export import telar.gui.core.json_writer;

// Interface: presentation/chrome_surfaces.cppm
export {
namespace telar::gui {

  // Separate navigation, gutters and pane bands without imposing a palette.
  struct ChromeSurfaces {
    Color navigation;
    Color workbench;
    Color pane;
    Color header;
    Color active_header;

    [[nodiscard]] inline static ChromeSurfaces derive(const Theme &theme, float opacity) noexcept {
      const auto panel = theme.chromeColor(PaletteRole::panel_bg);
      const auto ink = theme.chromeColor(PaletteRole::text);
      constexpr float navigation_mix = 0.09F;
      constexpr float header_mix = 0.055F;
      constexpr float active_header_mix = 0.09F;
      constexpr float gutter_mix = 0.28F;
      const bool translucent = opacity < 1;
      const auto band = [&](float amount) {
        return translucent ? Color{.r = ink.r, .g = ink.g, .b = ink.b, .a = amount} : mix(panel, ink, amount);
      };
      const auto background = theme.background;
      const auto end = background.r + background.g + background.b < 1.5F ? Color::rgb(0x000000) : Color::rgb(0xffffff);

      return {
          .navigation = band(navigation_mix),
          .workbench = translucent ? Color{.a = 0} : mix(background, end, gutter_mix),
          .pane = translucent ? Color{.a = 0} : panel,
          .header = band(header_mix),
          .active_header = band(active_header_mix),
      };
    }

  private:
    [[nodiscard]] inline static Color mix(Color base, Color ink, float amount) noexcept {
      return {
          .r = base.r + (ink.r - base.r) * amount,
          .g = base.g + (ink.g - base.g) * amount,
          .b = base.b + (ink.b - base.b) * amount,
          .a = 1,
      };
    }
  };

}
}

// Interface: presentation/display_metrics.cppm
export {
namespace telar::gui {

struct DisplayMetrics {
  double density = 1;
  Viewport viewport{};
  ChromeMetrics chrome{};
  WindowGeometry geometry{};

  [[nodiscard]] inline static DisplayMetrics resolve(const Configuration &configuration, Viewport logical_viewport, const CellMetrics &cells, double density) {
    if (!std::isfinite(density) || density <= 0 || density > Viewport::maximum_scale) {
      throw std::invalid_argument{"InvalidDisplayDensity"};
    }

    const Viewport physical{
        .width = physicalExtent(logical_viewport.width, density),
        .height = physicalExtent(logical_viewport.height, density),
        .scale = static_cast<float>(density),
        .controls = physicalExtent(logical_viewport.controls, density),
    };
    const auto chrome = ChromeMetrics::resolve(configuration, physical, cells);

    return {.density = density, .viewport = physical, .chrome = chrome, .geometry = WindowGeometry::measure(configuration, physical, cells, chrome)};
  }

private:
  [[nodiscard]] inline static std::uint32_t physicalExtent(std::uint32_t logical, double density) {
    const auto extent = std::round(logical * density);
    if (extent > std::numeric_limits<std::uint32_t>::max()) {
      throw std::out_of_range{"DisplayExtentOutOfRange"};
    }

    return static_cast<std::uint32_t>(extent);
  }
};

}
}

// Interface: presentation/history_command_line.cppm
export {
namespace telar::gui {

struct HistoryCommandMetrics {
  float needed = 0;
  float cell_width = 1;
  bool continues = false;
};

struct HistoryCommandLine {
  static constexpr float minimum_marked_columns = 2;
  static constexpr std::string_view ellipsis = "…";
  static constexpr std::string_view continuation = "↵";

  Rect text;
  Rect marker;
  std::string_view mark;

  [[nodiscard]] inline static HistoryCommandLine derive(Rect bounds, HistoryCommandMetrics metrics) noexcept {
    HistoryCommandLine result;
    result.text = bounds;
    const auto cell = std::max(1.0F, metrics.cell_width);
    const auto columns = std::floor(bounds.width / cell);
    const auto overflows = metrics.needed > bounds.width;
    if ((overflows || metrics.continues) && columns >= minimum_marked_columns) {
      const auto tail_limit = (columns - 1) * cell;
      result.text.width = overflows ? tail_limit : std::min(metrics.needed + cell, tail_limit);
      result.marker = {.x = bounds.x + result.text.width, .y = bounds.y, .width = cell, .height = bounds.height};
      result.mark = overflows ? ellipsis : continuation;
    }

    return result;
  }
};

}
}

// Interface: presentation/history_loading.cppm
export {
namespace telar::gui {

struct HistoryLoading {
  static constexpr std::uint64_t steps = 40;
  static constexpr std::uint64_t step_ns = 24'000'000;
  static constexpr float row_opacity = 0.55F;
  static constexpr float thickness = 2;
  static constexpr float span_divisor = 3;

  [[nodiscard]] inline static Rect line(Rect area, ChromeMetrics chrome, std::optional<std::uint64_t> now_ns) noexcept {
    const auto step = now_ns ? (*now_ns / step_ns) % steps : steps / 3;
    const auto span = area.width / span_divisor;
    const auto travel = area.width + span;
    const auto x = area.x - span + (travel * static_cast<float>(step) / static_cast<float>(steps));

    return {.x = x, .y = area.y, .width = span, .height = chrome.px(thickness)};
  }
};

}
}

// Interface: presentation/history_selection_motion.cppm
export {
namespace telar::gui {

struct HistoryPosition {
  std::size_t index = 0;
  std::uint64_t id = 0;

  bool operator==(const HistoryPosition &) const = default;
};

struct HistoryExpansion {
  float open = 1;
  std::optional<HistoryPosition> leaving;
  float leaving_open = 0;
};

class HistorySelectionMotion {
public:
  static constexpr std::uint64_t duration_ns = 140'000'000;

  [[nodiscard]] inline HistoryExpansion sample(std::optional<std::uint64_t> generation, std::optional<HistoryPosition> selected, std::optional<std::uint64_t> timestamp) noexcept {
    if (!generation || !selected) {
      *this = {};

      return {};
    }

    if (!timestamp || generation_ != generation) {
      *this = {};
      generation_ = generation;
      selected_ = *selected;

      return {};
    }

    if (selected_.index != selected->index) {
      leaving_from_ = eased(value(*timestamp));
      leaving_ = selected_;
      selected_ = *selected;
      started_ns_ = *timestamp;
      transitioning_ = true;
    } else if (selected_.id != selected->id) {
      selected_ = *selected;
      leaving_.reset();
      transitioning_ = false;
    }

    const auto open = eased(value(*timestamp));
    if (open >= 1) {
      leaving_.reset();
    }

    return {.open = open, .leaving = leaving_, .leaving_open = leaving_from_ * (1 - open)};
  }

  [[nodiscard]] inline std::optional<std::uint64_t> deadline(std::uint64_t now_ns, std::uint64_t interval_ns) const noexcept {
    if (!transitioning_) {
      return {};
    }

    if (now_ns < started_ns_) {
      return started_ns_;
    }

    if (now_ns - started_ns_ >= duration_ns) {
      return {};
    }

    return std::min(add(now_ns, interval_ns), add(started_ns_, duration_ns));
  }

private:
  [[nodiscard]] inline static std::uint64_t add(std::uint64_t left, std::uint64_t right) noexcept {
    return left + std::min(std::numeric_limits<std::uint64_t>::max() - left, right);
  }

  [[nodiscard]] inline static float eased(float progress) noexcept {
    const float remaining = 1 - progress;
    const float square = remaining * remaining;
    const float cube = square * remaining;

    return 1 - cube;
  }

  [[nodiscard]] inline float value(std::uint64_t now_ns) const noexcept {
    if (!transitioning_) {
      return 1;
    }

    if (now_ns < started_ns_) {
      return 0;
    }

    if (now_ns - started_ns_ >= duration_ns) {
      return 1;
    }

    return static_cast<float>(now_ns - started_ns_) / static_cast<float>(duration_ns);
  }

  std::optional<std::uint64_t> generation_;
  HistoryPosition selected_;
  std::optional<HistoryPosition> leaving_;
  float leaving_from_ = 1;
  std::uint64_t started_ns_ = 0;
  bool transitioning_ = false;
};

}
}

// Interface: presentation/progress_animation.cppm
export {
namespace telar::gui {

struct ProgressAnimation {
  static constexpr std::uint64_t period_ns = 1'400'000'000;
  static constexpr float minimum_fraction = 0.22F;
  static constexpr float fraction_range = 0.18F;

  struct Frame {
    float fraction = 0;
    float turns = 0;
  };

  template <Cosine Function = StandardCosine>
  [[nodiscard]] inline static Frame indeterminate(std::uint64_t now_ns) noexcept {
    const auto phase = static_cast<float>(now_ns % period_ns) / static_cast<float>(period_ns);
    const auto angle = phase * 2 * std::numbers::pi_v<float>;
    const auto cosine = Function::evaluate(angle);

    return {.fraction = minimum_fraction + (fraction_range * (1 - cosine)), .turns = phase};
  }

  [[nodiscard]] inline static std::uint64_t nextStep(std::uint64_t now_ns, std::uint64_t interval_ns) noexcept {
    const auto remaining = interval_ns - (now_ns % interval_ns);

    return now_ns + std::min(std::numeric_limits<std::uint64_t>::max() - now_ns, remaining);
  }
};

}
}

// Interface: presentation/progress_motion.cppm
export {
namespace telar::gui {

struct ProgressSample {
  static constexpr Byte maximum_percent = 100;
  std::uint64_t pane_id = 0;
  std::uint64_t attachment = 0;
  PaneProgressState state = PaneProgressState::remove;
  std::optional<Byte> percent = std::nullopt;

  [[nodiscard]] inline float reported() const noexcept {
    return static_cast<float>(std::min(percent.value_or(0), maximum_percent)) / maximum_percent;
  }

  bool operator==(const ProgressSample &) const = default;
};

class ProgressMotion {
public:
  static constexpr std::uint64_t duration_ns = 240'000'000;

  [[nodiscard]] inline float sample(ProgressSample report, std::uint64_t now_ns) noexcept {
    if (report.state == PaneProgressState::remove) {
      *this = {};
      return 0;
    }

    if (report.pane_id != pane_id_ || report.attachment != attachment_) {
      *this = {};
      pane_id_ = report.pane_id;
      attachment_ = report.attachment;
    }

    const auto target = report.reported();
    if (report.state != PaneProgressState::set || !report.percent || !known_) {
      from_ = target;
      to_ = target;
      known_ = report.percent.has_value() && report.state != PaneProgressState::indeterminate;
      duration_ = 0;

      return target;
    }

    if (target != to_) {
      from_ = value(now_ns);
      to_ = target;
      started_ns_ = now_ns;
      duration_ = from_ == target ? 0 : duration_ns;
    }

    return value(now_ns);
  }

  [[nodiscard]] inline std::optional<std::uint64_t> deadline(std::uint64_t now_ns) const noexcept {
    if (now_ns < started_ns_) {
      return started_ns_;
    }

    return now_ns - started_ns_ < duration_ ? std::optional{started_ns_ + std::min(std::numeric_limits<std::uint64_t>::max() - started_ns_, duration_)} : std::nullopt;
  }

private:
  [[nodiscard]] inline float value(std::uint64_t now_ns) const noexcept {
    float phase = 0;
    if (now_ns >= started_ns_) {
      if (duration_ == 0 || now_ns - started_ns_ >= duration_) {
        return to_;
      }

      phase = static_cast<float>(now_ns - started_ns_) / static_cast<float>(duration_);
    }

    const auto remaining = 1 - phase;
    const auto eased = 1 - (remaining * remaining * remaining);

    return std::clamp(from_ + ((to_ - from_) * eased), 0.0F, 1.0F);
  }

  std::uint64_t pane_id_ = 0;
  std::uint64_t attachment_ = 0;
  std::uint64_t started_ns_ = 0;
  std::uint64_t duration_ = 0;
  float from_ = 0;
  float to_ = 0;
  bool known_ = false;
};

}
}

// Interface: presentation/sidebar_columns.cppm
export {
namespace telar::gui {

struct SidebarColumns {
  static constexpr std::uint16_t minimum_width = 42;
  static constexpr std::uint16_t minimum_workbench = 20;

  [[nodiscard]] inline static std::uint16_t clamp(std::uint16_t host_width, std::int64_t requested_width) {
    if (requested_width <= 0 || std::cmp_greater(requested_width, std::numeric_limits<std::uint16_t>::max())) {
      throw std::invalid_argument{"InvalidWidth"};
    }

    if (host_width < minimum_width + minimum_workbench) {
      return minimum_width;
    }

    return std::clamp(static_cast<std::uint16_t>(requested_width), minimum_width, static_cast<std::uint16_t>(host_width - minimum_workbench));
  }
};

}
}
