module telar.gui.presentation.display_metrics;

import std;
import telar.wire.vocabulary;
import telar.gui.foundation.core;

namespace telar::gui {

  ChromeSurfaces ChromeSurfaces::derive(const Theme& theme, float fallback, const BackgroundOpacity& opacity) noexcept {
    const auto panel = theme.chromeColor(PaletteRole::panel_bg);
    const auto ink = theme.chromeColor(PaletteRole::text);
    const bool dark = theme.background.r + theme.background.g + theme.background.b < 1.5F;
    const auto gutter_end = Color::rgb(dark ? 0x000000 : 0xffffff);
    const auto text_end = Color::rgb(dark ? 0xffffff : 0x000000);
    const auto dim = theme.chromeColor(PaletteRole::surface_dim);
    const auto sheet = dim == panel ? mix(panel, gutter_end, 0.28F) : dim;

    return {
        .sidebar = alpha(sheet, opacity.resolve(BackgroundOpacity::Surface::sidebar, fallback)),
        .topbar = alpha(sheet, opacity.resolve(BackgroundOpacity::Surface::topbar, fallback)),
        .bottombar = alpha(sheet, opacity.resolve(BackgroundOpacity::Surface::bottombar, fallback)),
        .workbench = alpha(sheet, opacity.resolve(BackgroundOpacity::Surface::workspace, fallback)),
        .pane = alpha(panel, opacity.resolve(BackgroundOpacity::Surface::pane, fallback)),
        .text = mix(ink, text_end, 0.7F),
    };
  }

  Color ChromeSurfaces::alpha(Color color, float value) noexcept {
    color.a = value;
    return color;
  }

  Color ChromeSurfaces::mix(Color base, Color ink, float amount) noexcept {
    return {
        .r = base.r + (ink.r - base.r) * amount,
        .g = base.g + (ink.g - base.g) * amount,
        .b = base.b + (ink.b - base.b) * amount,
        .a = 1,
    };
  }

  DisplayMetrics DisplayMetrics::resolve(const Configuration& configuration, Viewport logical_viewport, const CellMetrics& cells, double density) {
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

  std::uint32_t DisplayMetrics::physicalExtent(std::uint32_t logical, double density) {
    const auto extent = std::round(logical * density);
    if (extent > std::numeric_limits<std::uint32_t>::max()) {
      throw std::out_of_range{"DisplayExtentOutOfRange"};
    }

    return static_cast<std::uint32_t>(extent);
  }

  std::uint64_t ProgressAnimation::nextStep(std::uint64_t now_ns, std::uint64_t interval_ns) noexcept {
    const auto remaining = interval_ns - (now_ns % interval_ns);

    return now_ns + std::min(std::numeric_limits<std::uint64_t>::max() - now_ns, remaining);
  }

  float ProgressSample::reported() const noexcept {
    return static_cast<float>(std::min(percent.value_or(0), maximum_percent)) / maximum_percent;
  }

  float ProgressMotion::sample(ProgressSample report, std::uint64_t now_ns) noexcept {
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

  std::optional<std::uint64_t> ProgressMotion::deadline(std::uint64_t now_ns) const noexcept {
    if (now_ns < started_ns_) {
      return started_ns_;
    }

    return now_ns - started_ns_ < duration_ ? std::optional{started_ns_ + std::min(std::numeric_limits<std::uint64_t>::max() - started_ns_, duration_)} : std::nullopt;
  }

  float ProgressMotion::value(std::uint64_t now_ns) const noexcept {
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

}
