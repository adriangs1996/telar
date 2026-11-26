module;

// How the panel moves: the selection gliding between rows, a command line unfolding and the
// loading cue.
export module telar.gui.features.history:motion;

import std;

import telar.gui.foundation.core;
import telar.base.ds;

// Interface: presentation/history_command_line.cppm
export {
  namespace telar::gui::features::history {

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
  namespace telar::gui::features::history {

    struct HistoryLoading {
      static constexpr std::uint64_t steps = 40;
      static constexpr std::uint64_t step_ns = 24'000'000;
      static constexpr float row_opacity = 0.55F;
      static constexpr float thickness = 2;
      static constexpr float span_divisor = 3;

      [[nodiscard]] static Rect line(Rect area, ChromeMetrics chrome, ds::Option<std::uint64_t> now_ns) noexcept;
    };

  }
}

// Interface: presentation/history_selection_motion.cppm
export {
  namespace telar::gui::features::history {

    struct HistoryPosition {
      std::size_t index = 0;
      std::uint64_t id = 0;

      bool operator==(const HistoryPosition&) const = default;
    };

    struct HistoryExpansion {
      float open = 1;
      ds::Option<HistoryPosition> leaving;
      float leaving_open = 0;
    };

    class HistorySelectionMotion {
    public:
      static constexpr std::uint64_t duration_ns = 140'000'000;

      [[nodiscard]] HistoryExpansion sample(ds::Option<std::uint64_t> generation, ds::Option<HistoryPosition> selected, ds::Option<std::uint64_t> timestamp) noexcept;
      [[nodiscard]] ds::Option<std::uint64_t> deadline(std::uint64_t now_ns, std::uint64_t interval_ns) const noexcept;

    private:
      [[nodiscard]] static std::uint64_t add(std::uint64_t left, std::uint64_t right) noexcept;
      [[nodiscard]] static float eased(float progress) noexcept;
      [[nodiscard]] float value(std::uint64_t now_ns) const noexcept;

      ds::Option<std::uint64_t> generation_;
      HistoryPosition selected_;
      ds::Option<HistoryPosition> leaving_;
      float leaving_from_ = 1;
      std::uint64_t started_ns_ = 0;
      bool transitioning_ = false;
    };

  }
}
