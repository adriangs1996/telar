module;
#include "tbc/annotations.hpp"

// The cards the window paints for the notices: their geometry, the label of their action and
// the stack that moves them as notices come and go. Each window holds its own stack.
export module telar.gui.features.notifications:stack;

import std;
import telar.tbc;

import :center;
import telar.gui.foundation.core;
import telar.gui.foundation.text;
import telar.wire.vocabulary;
import telar.base.ds;

// Interface: presentation/notification_action_label.cppm
export {
  namespace telar::gui::features::notifications {

    struct NotificationActionLabel {
      static constexpr std::size_t decoration_bytes = 16;
      using Buffer = BoundedText<max_notification_link_bytes + decoration_bytes>;

      [[nodiscard]] static constexpr std::string_view target(NotificationTarget::Kind kind) noexcept {
        switch (kind) {
        case NotificationTarget::Kind::pane:
          return "Open pane →";
        case NotificationTarget::Kind::tab:
          return "Open tab →";
        case NotificationTarget::Kind::workspace:
          return "Open workspace →";
        case NotificationTarget::Kind::none:
          return {};
        }

        return {};
      }

      // Generic over the caller's measure, so it stays here.
      template <LabelMeasure Measure>
      [[nodiscard]] TBC_GENERIC static tbc::view<std::string_view, tbc::lt::a> fitHost(tbc::view<std::string_view, tbc::lt::a> host, float width, Measure& measure, tbc::view<Buffer&, tbc::lt::a> buffer) {
        if (!std::isfinite(width) || width < 0) {
          throw std::invalid_argument{"InvalidNotificationActionWidth"};
        }

        format(host, false, buffer);
        const auto full = static_cast<float>(measure(buffer.view()));
        if (!std::isfinite(full) || full <= 0) {
          throw std::invalid_argument{"InvalidNotificationActionMeasurement"};
        }

        if (full <= width) {
          return buffer.view();
        }

        auto keep = std::min(host.size(), static_cast<std::size_t>(std::floor(static_cast<float>(host.size()) * width / full)));

        while (keep > 0) {
          format(host.substr(host.size() - keep), true, buffer);
          if (measure(buffer.view()) <= width) {
            return buffer.view();
          }

          --keep;
        }

        buffer.truncate(0);
        buffer.append("Open ↗");

        return buffer.view();
      }

    private:
      static void format(std::string_view host, bool truncated, Buffer& buffer);
    };

  }
}

// Interface: presentation/notification_geometry.cppm
export {
  namespace telar::gui::features::notifications {

    struct NotificationMetrics {
      static constexpr float margin = 16;
      static constexpr float preferred_width = 360;
      static constexpr float minimum_width = 160;
      static constexpr float minimum_host_height = 96;
      static constexpr float minimum_card_height = 64;
      static constexpr float card_padding = 14;
      static constexpr float vertical_padding = 28;
      static constexpr float body_gap = 4;
      static constexpr float action_gap = 10;
      static constexpr float stack_gap = 10;
      static constexpr float enter_shift_x = 12;
      static constexpr float enter_shift_y = 6;
      static constexpr float radius = 12;
      static constexpr float icon_side = 28;
      static constexpr float icon_radius = 9;
      static constexpr float text_left = 54;
      static constexpr float text_insets = 76;
      static constexpr float title_insets = 94;
      static constexpr float body_top = 18;
      static constexpr float close_right = 34;
      static constexpr float close_top = 8;
      static constexpr float close_side = 26;
      static constexpr float close_radius = 7;
      static constexpr float border_width = 1;
      static constexpr float border_alpha = 0.35F;
      static constexpr float focus_border_width = 1.5F;
      static constexpr float icon_alpha = 0.14F;
      static constexpr std::size_t shadow_layers = 3;
      static constexpr float shadow_spread = 2;
      static constexpr float shadow_offset = 3;
      static constexpr float shadow_alpha = 0.055F;
      static constexpr float underline_bottom = 2;
      static constexpr float underline_height = 1;

      float ratio = 1;
      float title_row = ChromeMetrics::lineHeight(ChromeMetrics{}.title);
      float body_row = ChromeMetrics::lineHeight(ChromeMetrics{}.body);
      float small_row = ChromeMetrics::lineHeight(ChromeMetrics{}.small);

      [[nodiscard]] float px(float value) const noexcept;
      [[nodiscard]] float height(std::size_t body_lines, bool clickable) const noexcept;
    };

    struct NotificationCardGeometry {
      Rect bounds;
      NotificationMetrics metrics;

      [[nodiscard]] Rect icon() const noexcept;
      [[nodiscard]] Rect title() const noexcept;
      [[nodiscard]] Rect body(std::size_t row) const noexcept;
      [[nodiscard]] Rect action() const noexcept;
      [[nodiscard]] Rect close() const noexcept;
      [[nodiscard]] Rect actionUnderline(float line_height, float advance) const noexcept;
      [[nodiscard]] float bodyWidth() const noexcept;

    private:
      [[nodiscard]] float textLeft() const noexcept;
    };

  }
}

// Interface: presentation/notification_stack.cppm
export {
  namespace telar::gui::features::notifications {

    struct NotificationPlacement {
      std::size_t index = 0;
      NotificationId id{};
      Rect bounds;
      float opacity = 0;
    };

    struct NotificationStackRequest {
      std::span<const NotificationItem> items;
      Rect host;
      float ratio = 1;
      std::uint64_t now_ns = 0;
    };

    template <typename Hidden>
    concept NotificationHidden = requires(Hidden& hidden, const NotificationItem& item) {
      { hidden(item) } -> std::convertible_to<bool>;
    };

    template <typename Measure>
    concept NotificationHeight = requires(Measure& measure, const NotificationItem& item, float width) {
      { measure(item, width) } -> std::convertible_to<float>;
    };

    class NotificationStack {
    public:
      static constexpr std::size_t maximum_visible = 2;
      static constexpr std::uint64_t motion_duration_ns = 180'000'000;

      struct Cards {
        std::array<NotificationPlacement, maximum_visible> placements;
        std::size_t count = 0;

        [[nodiscard]] std::span<const NotificationPlacement> items() const noexcept;
      };

      // Generic over the caller's filter and measure, so it stays here; it runs once per frame.
      template <NotificationHidden Hidden, NotificationHeight Measure>
      [[nodiscard]] TBC_GENERIC Cards prepare(NotificationStackRequest request, Hidden hidden, Measure measure) {
        Cards result;
        const auto margin = NotificationMetrics::margin * request.ratio;
        const auto width = std::min(NotificationMetrics::preferred_width * request.ratio, request.host.width - (2 * margin));
        if (width < NotificationMetrics::minimum_width * request.ratio || request.host.height < NotificationMetrics::minimum_host_height * request.ratio) {
          motions_ = {};
          return result;
        }

        std::array<bool, NotificationCenter::capacity> used{};
        auto y = request.host.y + margin;
        std::size_t painted = 0;
        std::array<NotificationPlacement, maximum_visible> cards;

        for (std::size_t index = 0; index < request.items.size() && painted < maximum_visible; ++index) {
          const auto& item = request.items[index];
          if (hidden(item) || (item.phase == NotificationItem::Phase::exiting && item.transition_position_ns == 0)) {
            continue;
          }

          Rect bounds{.x = request.host.x + request.host.width - margin - width, .y = y, .width = width, .height = measure(item, width)};
          if (y + bounds.height > request.host.y + request.host.height - margin) {
            break;
          }

          const auto opacity = item.opacity(request.now_ns);
          if (opacity == 0 && item.phase == NotificationItem::Phase::exiting) {
            continue;
          }

          if (const auto slot = motion(item.id, y)) {
            used[*slot] = true;
            bounds.y = motions_[*slot].position(y, request);
          }

          bounds.x += NotificationMetrics::enter_shift_x * request.ratio * (1 - opacity);
          bounds.y += NotificationMetrics::enter_shift_y * request.ratio * (1 - opacity);
          y += bounds.height + (NotificationMetrics::stack_gap * request.ratio);
          cards[painted++] = {.index = index, .id = item.id, .bounds = bounds, .opacity = opacity};
        }

        while (painted > 0) {
          const auto& card = cards[--painted];
          if (card.opacity > 0) {
            result.placements[result.count++] = card;
          }
        }

        for (std::size_t index = 0; index < motions_.size(); ++index) {
          if (!used[index]) {
            motions_[index] = {};
          }
        }

        return result;
      }

      [[nodiscard]] ds::Option<std::uint64_t> nextDeadline(std::uint64_t now_ns, std::uint64_t interval_ns) const noexcept;

    private:
      struct Motion {
        NotificationId id{};
        float from = 0;
        float to = 0;
        std::uint64_t started_ns = 0;

        float position(float target, const NotificationStackRequest& frame) noexcept;
        [[nodiscard]] float value(std::uint64_t now_ns) const noexcept;
      };

      [[nodiscard]] ds::Option<std::size_t> motion(NotificationId id, float y) noexcept;

      std::array<Motion, NotificationCenter::capacity> motions_{};
    };

  }
}
