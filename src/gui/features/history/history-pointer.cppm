module;

// The pointer over the panel: scrolling its list, pressing its actions and what it hovers.
export module telar.gui.features.history:pointer;

import std;

import :entry;
import :filters;
import :cards;
import telar.gui.foundation.core;
import telar.base.ds;

// Interface: input/history_action_capture.cppm
export {
  namespace telar::gui::features::history {

    struct HistoryActionPosition {
      double x = 0;
      double y = 0;
    };

    struct HistoryActionTarget {
      HistoryCardAction action = HistoryCardAction::copy;
      Rect bounds{};
      bool enabled = false;

      [[nodiscard]] bool contains(HistoryActionPosition position) const noexcept;
    };

    struct HistoryActionSurface {
      ds::Array<HistoryActionTarget, HistoryActions::count> targets{};
      std::uint64_t generation = 0;
      double scale = 1;
      ds::Option<HistoryChoice> choice = ds::none;

      [[nodiscard]] const HistoryActionTarget* find(HistoryCardAction action) const noexcept;
    };

    class HistoryActionCapture {
    public:
      [[nodiscard]] bool begin(const HistoryActionSurface& surface, HistoryActionPosition position, bool primary) noexcept;
      [[nodiscard]] bool held() const noexcept;
      void cancel() noexcept;
      void present(const HistoryActionSurface& surface) noexcept;
      [[nodiscard]] ds::Option<HistoryCardAction> release(const HistoryActionSurface& surface, HistoryActionPosition position) noexcept;

    private:
      ds::Option<HistoryCardAction> action_;
      ds::Option<HistoryChoice> choice_;
      std::uint64_t generation_ = 0;
      bool held_ = false;
    };

  }
}

// Interface: input/history_hover.cppm
export {
  namespace telar::gui::features::history {

    enum class HistoryFilterAction : std::uint8_t {
      global,
      workspace,
      cwd,
      pane,
      human,
      agent,
      all,
      failed,
    };

    inline constexpr std::size_t history_filter_target_count = 8;

    struct HistoryFooterIdentity {
      HistoryFooterAction action = HistoryFooterAction::none;
      HistoryChoice choice;

      [[nodiscard]] bool submission() const noexcept;

      bool operator==(const HistoryFooterIdentity& other) const noexcept;
    };

    struct HistoryInspectionIdentity {
      HistoryInspectionAction action = HistoryInspectionAction::submit;
      HistoryChoice choice;

      [[nodiscard]] bool submission() const noexcept;

      bool operator==(const HistoryInspectionIdentity& other) const noexcept;
    };

    struct HistoryHoverIdentity {
      std::variant<HistoryChoice, HistoryCardAction, HistoryFooterIdentity, HistoryFilterAction, HistoryInspectionIdentity> action;
      std::uint64_t generation = 0;

      bool operator==(const HistoryHoverIdentity& other) const noexcept;
    };

    struct HistoryHoverTarget {
      HistoryHoverIdentity identity;
      Rect bounds{};

      [[nodiscard]] bool contains(HistoryActionPosition position) const noexcept;
    };

    class HistoryHover {
    public:
      enum class Observation : std::uint8_t {
        point,
        retained,
        leave,
      };

      [[nodiscard]] const ds::Option<HistoryHoverIdentity>& hovered() const noexcept;
      bool cancel() noexcept;
      bool present(std::span<const HistoryHoverTarget> targets) noexcept;
      bool observe(std::span<const HistoryHoverTarget> targets, HistoryActionPosition position, Observation observation) noexcept;

    private:
      ds::Option<HistoryHoverIdentity> hovered_;
    };

  }
}

// Interface: input/history_scroll.cppm
export {
  namespace telar::gui::features::history {

    struct HistoryScrollState {
      std::uint64_t generation = 0;
      std::uint64_t revision = 0;
      bool ready = false;
      bool inspecting = false;
    };

    struct HistoryScrollSurface {
      Rect bounds{};
      std::uint64_t generation = 0;
      std::uint64_t revision = 0;
      double row_height = 1;
      double cell_height = 1;
      double scale = 1;
      bool delivered = false;
      bool has_rows = false;
    };

    struct HistoryScrollPosition {
      double x = 0;
      double y = 0;
    };

    class HistoryScroll {
    public:
      [[nodiscard]] std::int32_t consume(HistoryScrollState state, const HistoryScrollSurface& surface, HistoryScrollPosition pointer, ScrollSample sample) noexcept;

    private:
      [[nodiscard]] static bool within(Rect bounds, HistoryScrollPosition pointer) noexcept;

      WheelAccumulator wheel_;
      std::uint64_t generation_ = 0;
      bool inspecting_ = false;
    };

  }
}
