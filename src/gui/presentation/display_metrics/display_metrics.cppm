module;
#include "tbc/annotations.hpp"

export module telar.gui.presentation.display_metrics;

import std;

import telar.gui.core.metrics;

import telar.gui.core.json_writer;
import telar.base.diagnostics;
import telar.gui.core.primitives;
import telar.wire.vocabulary;

// Interface: presentation/chrome_surfaces.cppm
export {
  namespace telar::gui {

    // Background alphas are final surface opacities, not stacked tints.
    struct ChromeSurfaces {
      Color sidebar;
      Color topbar;
      Color bottombar;
      Color workbench;
      Color pane;
      Color text;

      [[nodiscard]] static ChromeSurfaces derive(const Theme& theme, float fallback, const BackgroundOpacity& opacity = {}) noexcept;

    private:
      [[nodiscard]] static Color alpha(Color color, float value) noexcept;
      [[nodiscard]] static Color mix(Color base, Color ink, float amount) noexcept;
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

      [[nodiscard]] static DisplayMetrics resolve(const Configuration& configuration, Viewport logical_viewport, const CellMetrics& cells, double density);

    private:
      [[nodiscard]] static std::uint32_t physicalExtent(std::uint32_t logical, double density);
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

      [[nodiscard]] static HistoryCommandLine derive(Rect bounds, HistoryCommandMetrics metrics) noexcept;
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

      [[nodiscard]] static Rect line(Rect area, ChromeMetrics chrome, std::optional<std::uint64_t> now_ns) noexcept;
    };

  }
}

// Interface: presentation/history_selection_motion.cppm
export {
  namespace telar::gui {

    struct HistoryPosition {
      std::size_t index = 0;
      std::uint64_t id = 0;

      bool operator==(const HistoryPosition&) const = default;
    };

    struct HistoryExpansion {
      float open = 1;
      std::optional<HistoryPosition> leaving;
      float leaving_open = 0;
    };

    class HistorySelectionMotion {
    public:
      static constexpr std::uint64_t duration_ns = 140'000'000;

      [[nodiscard]] HistoryExpansion sample(std::optional<std::uint64_t> generation, std::optional<HistoryPosition> selected, std::optional<std::uint64_t> timestamp) noexcept;
      [[nodiscard]] std::optional<std::uint64_t> deadline(std::uint64_t now_ns, std::uint64_t interval_ns) const noexcept;

    private:
      [[nodiscard]] static std::uint64_t add(std::uint64_t left, std::uint64_t right) noexcept;
      [[nodiscard]] static float eased(float progress) noexcept;
      [[nodiscard]] float value(std::uint64_t now_ns) const noexcept;

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

      // Generic over the caller's cosine, so it stays here; a few float operations per frame.
      template <Cosine Function = StandardCosine>
      [[nodiscard]] TBC_GENERIC static Frame indeterminate(std::uint64_t now_ns) noexcept {
        const auto phase = static_cast<float>(now_ns % period_ns) / static_cast<float>(period_ns);
        const auto angle = phase * 2 * std::numbers::pi_v<float>;
        const auto cosine = Function::evaluate(angle);

        return {.fraction = minimum_fraction + (fraction_range * (1 - cosine)), .turns = phase};
      }

      [[nodiscard]] static std::uint64_t nextStep(std::uint64_t now_ns, std::uint64_t interval_ns) noexcept;
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

      [[nodiscard]] float reported() const noexcept;

      bool operator==(const ProgressSample&) const = default;
    };

    class ProgressMotion {
    public:
      static constexpr std::uint64_t duration_ns = 240'000'000;

      [[nodiscard]] float sample(ProgressSample report, std::uint64_t now_ns) noexcept;
      [[nodiscard]] std::optional<std::uint64_t> deadline(std::uint64_t now_ns) const noexcept;

    private:
      [[nodiscard]] float value(std::uint64_t now_ns) const noexcept;

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

      [[nodiscard]] static std::uint16_t clamp(std::uint16_t host_width, std::int64_t requested_width);
    };

  }
}
