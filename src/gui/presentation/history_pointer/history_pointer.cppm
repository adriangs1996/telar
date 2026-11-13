export module telar.gui.presentation.history_pointer;

import std;

export import telar.gui.core.metrics;
export import telar.gui.history.browser;
export import telar.gui.presentation.history_filter_geometry;
export import telar.gui.presentation.history_meta_geometry;

// Interface: input/history_action_capture.cppm
export {
  namespace telar::gui {

    struct HistoryActionPosition {
      double x = 0;
      double y = 0;
    };

    struct HistoryActionTarget {
      HistoryCardAction action = HistoryCardAction::copy;
      Rect bounds{};
      bool enabled = false;

      [[nodiscard]] inline bool contains(HistoryActionPosition position) const noexcept {
        return position.x >= bounds.x && position.y >= bounds.y && position.x < static_cast<double>(bounds.x) + bounds.width && position.y < static_cast<double>(bounds.y) + bounds.height;
      }
    };

    struct HistoryActionSurface {
      std::array<HistoryActionTarget, HistoryActions::count> targets{};
      std::uint64_t generation = 0;
      double scale = 1;
      std::optional<HistoryChoice> choice = std::nullopt;

      [[nodiscard]] inline const HistoryActionTarget* find(HistoryCardAction action) const noexcept {
        for (const auto& target : targets) {
          if (target.action == action && !target.bounds.empty()) {
            return &target;
          }
        }

        return nullptr;
      }
    };

    class HistoryActionCapture {
    public:
      [[nodiscard]] inline bool begin(const HistoryActionSurface& surface, HistoryActionPosition position, bool primary) noexcept {
        *this = {};
        for (std::size_t index = surface.targets.size(); index > 0; --index) {
          const auto& target = surface.targets[index - 1];
          if (!target.bounds.empty() && target.contains(position)) {
            held_ = true;
            generation_ = surface.generation;
            choice_ = surface.choice;
            if (primary && target.enabled) {
              action_ = target.action;
            }

            return true;
          }
        }

        return false;
      }

      [[nodiscard]] inline bool held() const noexcept {
        return held_;
      }

      inline void cancel() noexcept {
        action_.reset();
      }

      inline void present(const HistoryActionSurface& surface) noexcept {
        const auto* target = action_ ? surface.find(*action_) : nullptr;
        if (surface.generation != generation_ || surface.choice != choice_ || target == nullptr || !target->enabled) {
          cancel();
        }
      }

      [[nodiscard]] inline std::optional<HistoryCardAction> release(const HistoryActionSurface& surface, HistoryActionPosition position) noexcept {
        present(surface);
        held_ = false;
        const auto action = std::exchange(action_, std::nullopt);
        const auto* target = action ? surface.find(*action) : nullptr;

        return target != nullptr && target->contains(position) ? action : std::nullopt;
      }

    private:
      std::optional<HistoryCardAction> action_;
      std::optional<HistoryChoice> choice_;
      std::uint64_t generation_ = 0;
      bool held_ = false;
    };

  }
}

// Interface: input/history_hover.cppm
export {
  namespace telar::gui {

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

      [[nodiscard]] inline bool submission() const noexcept {
        return action == HistoryFooterAction::submit || action == HistoryFooterAction::alternate;
      }

      bool operator==(const HistoryFooterIdentity& other) const noexcept {
        return action == other.action && (!submission() || choice == other.choice);
      }
    };

    struct HistoryInspectionIdentity {
      HistoryInspectionAction action = HistoryInspectionAction::submit;
      HistoryChoice choice;

      [[nodiscard]] inline bool submission() const noexcept {
        return action == HistoryInspectionAction::submit || action == HistoryInspectionAction::alternate;
      }

      bool operator==(const HistoryInspectionIdentity& other) const noexcept {
        return action == other.action && (!submission() || choice == other.choice);
      }
    };

    struct HistoryHoverIdentity {
      std::variant<HistoryChoice, HistoryCardAction, HistoryFooterIdentity, HistoryFilterAction, HistoryInspectionIdentity> action;
      std::uint64_t generation = 0;

      bool operator==(const HistoryHoverIdentity& other) const noexcept {
        if (generation != other.generation) {
          return false;
        }

        if (const auto* row = std::get_if<HistoryChoice>(&action)) {
          const auto* other_row = std::get_if<HistoryChoice>(&other.action);

          return other_row != nullptr && *row == *other_row;
        }

        const auto* card = std::get_if<HistoryCardAction>(&action);
        const auto* other_card = std::get_if<HistoryCardAction>(&other.action);

        if (card != nullptr) {
          return other_card != nullptr && *card == *other_card;
        }

        const auto* footer = std::get_if<HistoryFooterIdentity>(&action);
        const auto* other_footer = std::get_if<HistoryFooterIdentity>(&other.action);

        if (footer != nullptr) {
          return other_footer != nullptr && *footer == *other_footer;
        }

        const auto* filter = std::get_if<HistoryFilterAction>(&action);
        const auto* other_filter = std::get_if<HistoryFilterAction>(&other.action);

        if (filter != nullptr) {
          return other_filter != nullptr && *filter == *other_filter;
        }

        const auto* inspection = std::get_if<HistoryInspectionIdentity>(&action);
        const auto* other_inspection = std::get_if<HistoryInspectionIdentity>(&other.action);

        return inspection != nullptr && other_inspection != nullptr && *inspection == *other_inspection;
      }
    };

    struct HistoryHoverTarget {
      HistoryHoverIdentity identity;
      Rect bounds{};

      [[nodiscard]] inline bool contains(HistoryActionPosition position) const noexcept {
        return position.x >= bounds.x && position.y >= bounds.y && position.x < static_cast<double>(bounds.x) + bounds.width && position.y < static_cast<double>(bounds.y) + bounds.height;
      }
    };

    class HistoryHover {
    public:
      enum class Observation : std::uint8_t {
        point,
        retained,
        leave,
      };

      [[nodiscard]] inline const std::optional<HistoryHoverIdentity>& hovered() const noexcept {
        return hovered_;
      }

      inline bool cancel() noexcept {
        const bool changed = hovered_.has_value();

        hovered_.reset();

        return changed;
      }

      inline bool present(std::span<const HistoryHoverTarget> targets) noexcept {
        if (hovered_ && std::ranges::none_of(targets, [&](const HistoryHoverTarget& target) {
              return target.identity == *hovered_ && !target.bounds.empty();
            })) {
          return cancel();
        }

        return false;
      }

      inline bool observe(std::span<const HistoryHoverTarget> targets, HistoryActionPosition position, Observation observation) noexcept {
        if (observation == Observation::retained) {
          return false;
        }

        std::optional<HistoryHoverIdentity> next;

        if (observation == Observation::point) {
          for (auto index = targets.size(); index > 0; --index) {
            const auto& target = targets[index - 1];
            if (!target.bounds.empty() && target.contains(position)) {
              next = target.identity;
              break;
            }
          }
        }

        const bool changed = next != hovered_;

        hovered_ = next;

        return changed;
      }

    private:
      std::optional<HistoryHoverIdentity> hovered_;
    };

  }
}
