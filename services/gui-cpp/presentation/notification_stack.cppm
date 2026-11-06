module;

#include "telar_client/serializers/telar_messages.hpp"
#include <array>
#include <charconv>
#include <concepts>
#include <cstddef>
#include <cstring>
#include <stdexcept>
#include <string_view>
#include <system_error>


#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include <algorithm>
#include <cstdint>
#include <limits>
#include <bit>
#include <optional>
#include <ghostty/vt/unicode.h>
#include <cmath>


#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "../core/terminal_size.hpp"


#include <span>


#include "../core/memory.hpp"
#include <atomic>
#include <exception>
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_config/graphics/limits.hpp"
#include <utility>
#include <variant>
#include "../terminal/screen.hpp"

export module telar.gui.presentation.notification_stack;

export import telar.gui.text.json_unsigned_integer;


export import telar.gui.application.workspace_replica;


export import telar.gui.core.metrics;

// Interface: presentation/agent_card_labels.cppm
export {
namespace telar::gui {

struct AgentCardLabels {
  static constexpr std::string_view generic_name = "Agent";
  static constexpr std::string_view separator = " · ";
  static constexpr std::string_view coordinator_suffix = " · coordinator";
  static constexpr std::size_t workspace_capacity = 48;
  static constexpr std::size_t machine_capacity = 32;
  static constexpr std::size_t suffix_capacity = 32;
  using Project = BoundedText<workspace_capacity + machine_capacity + suffix_capacity>;

  [[nodiscard]] inline static std::string_view title(std::string_view session, std::string_view display_name) noexcept {
    if (!session.empty()) {
      return session;
    }

    return display_name.empty() ? generic_name : display_name;
  }

  [[nodiscard]] inline static std::string_view providerGlyph(AgentProvider provider, std::string_view custom) noexcept {
    if (!custom.empty()) {
      return custom;
    }

    switch (provider) {
    case AgentProvider::claude:
      return "\u2733";
    case AgentProvider::codex:
      return "\u25c6";
    case AgentProvider::pi:
      return "\u03c0";
    case AgentProvider::cursor:
      return "\u2b22";
    case AgentProvider::opencode:
      return "\u25a3";
    default:
      return "?";
    }
  }

  [[nodiscard]] inline static std::string_view project(std::string_view workspace, std::string_view machine, bool coordinator, Project &storage) {
    storage.truncate(0);
    try {
      if (!machine.empty()) {
        storage.append(machine);
        storage.append(separator);
      }

      storage.append(workspace);
      if (coordinator) {
        storage.append(coordinator_suffix);
      }

      return storage.view();
    } catch (const std::length_error &) {
      return machine.empty() ? workspace : machine;
    }
  }
};

}
}

// Interface: presentation/notification_action_label.cppm
export {
namespace telar::gui {

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

  template <LabelMeasure Measure>
  [[nodiscard]] inline static std::string_view fitHost(std::string_view host, float width, Measure &measure, Buffer &buffer) {
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
  inline static void format(std::string_view host, bool truncated, Buffer &buffer) {
    buffer.truncate(0);
    buffer.append(truncated ? "Open …" : "Open ");
    buffer.append(host);
    buffer.append(" ↗");
  }
};

}
}

// Interface: presentation/notification_geometry.cppm
export {
namespace telar::gui {

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

  [[nodiscard]] inline float px(float value) const noexcept {
    return value * ratio;
  }

  [[nodiscard]] inline float height(std::size_t body_lines, bool clickable) const noexcept {
    auto height = px(vertical_padding) + title_row;
    if (body_lines > 0) {
      height += px(body_gap) + (static_cast<float>(body_lines) * body_row);
    }

    if (clickable) {
      height += px(action_gap) + small_row;
    }

    return std::max(height, px(minimum_card_height));
  }
};

struct NotificationCardGeometry {
  Rect bounds;
  NotificationMetrics metrics;

  [[nodiscard]] inline Rect icon() const noexcept {
    return {.x = bounds.x + metrics.px(NotificationMetrics::card_padding), .y = bounds.y + metrics.px(NotificationMetrics::card_padding), .width = metrics.px(NotificationMetrics::icon_side), .height = metrics.px(NotificationMetrics::icon_side)};
  }

  [[nodiscard]] inline Rect title() const noexcept {
    return {.x = textLeft(), .y = bounds.y + metrics.px(NotificationMetrics::card_padding), .width = bounds.width - metrics.px(NotificationMetrics::title_insets), .height = metrics.title_row};
  }

  [[nodiscard]] inline Rect body(std::size_t row) const noexcept {
    auto y = bounds.y + metrics.px(NotificationMetrics::body_top) + metrics.title_row;
    for (std::size_t index = 0; index < row; ++index) {
      y += metrics.body_row;
    }

    return {.x = textLeft(), .y = y, .width = bodyWidth(), .height = metrics.body_row};
  }

  [[nodiscard]] inline Rect action() const noexcept {
    return {.x = textLeft(), .y = bounds.y + bounds.height - metrics.px(NotificationMetrics::card_padding) - metrics.small_row, .width = bodyWidth(), .height = metrics.small_row};
  }

  [[nodiscard]] inline Rect close() const noexcept {
    return {.x = bounds.x + bounds.width - metrics.px(NotificationMetrics::close_right), .y = bounds.y + metrics.px(NotificationMetrics::close_top), .width = metrics.px(NotificationMetrics::close_side), .height = metrics.px(NotificationMetrics::close_side)};
  }

  [[nodiscard]] inline Rect actionUnderline(float line_height, float advance) const noexcept {
    const auto row = action();
    const auto top = std::floor(row.y + ((row.height - line_height) / 2));

    return {.x = row.x, .y = top + line_height - NotificationMetrics::underline_bottom, .width = std::min(row.width, advance), .height = NotificationMetrics::underline_height};
  }

  [[nodiscard]] inline float bodyWidth() const noexcept {
    return bounds.width - metrics.px(NotificationMetrics::text_insets);
  }

private:
  [[nodiscard]] inline float textLeft() const noexcept {
    return bounds.x + metrics.px(NotificationMetrics::text_left);
  }
};

}
}

// Interface: presentation/notification_stack.cppm
export {
namespace telar::gui {

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
concept NotificationHidden = requires(Hidden &hidden, const NotificationItem &item) {
  { hidden(item) } -> std::convertible_to<bool>;
};

template <typename Measure>
concept NotificationHeight = requires(Measure &measure, const NotificationItem &item, float width) {
  { measure(item, width) } -> std::convertible_to<float>;
};

class NotificationStack {
public:
  static constexpr std::size_t maximum_visible = 2;
  static constexpr std::uint64_t motion_duration_ns = 180'000'000;

  struct Cards {
    std::array<NotificationPlacement, maximum_visible> placements;
    std::size_t count = 0;

    [[nodiscard]] inline std::span<const NotificationPlacement> items() const noexcept {
      return std::span{placements}.first(count);
    }
  };

  template <NotificationHidden Hidden, NotificationHeight Measure>
  [[nodiscard]] inline Cards prepare(NotificationStackRequest request, Hidden hidden, Measure measure) {
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
      const auto &item = request.items[index];
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
      const auto &card = cards[--painted];
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

  [[nodiscard]] inline std::optional<std::uint64_t> nextDeadline(std::uint64_t now_ns, std::uint64_t interval_ns) const noexcept {
    std::optional<std::uint64_t> earliest;
    for (const auto &motion : motions_) {
      if (motion.id.value == 0 || motion.from == motion.to || (now_ns >= motion.started_ns && now_ns - motion.started_ns >= motion_duration_ns)) {
        continue;
      }

      const auto deadline = std::min(NotificationItem::deadlineAfter(now_ns, interval_ns), NotificationItem::deadlineAfter(motion.started_ns, motion_duration_ns));
      earliest = earliest ? std::min(*earliest, deadline) : deadline;
    }

    return earliest;
  }

private:
  struct Motion {
    NotificationId id{};
    float from = 0;
    float to = 0;
    std::uint64_t started_ns = 0;

    inline float position(float target, const NotificationStackRequest &frame) noexcept {
      const auto now_ns = frame.now_ns;
      if (to != target) {
        from = value(now_ns);
        to = target;
        started_ns = now_ns;
      }

      return value(now_ns);
    }

    [[nodiscard]] inline float value(std::uint64_t now_ns) const noexcept {
      constexpr float quadratic_weight = 3;
      constexpr float cubic_weight = 2;
      const auto elapsed = now_ns >= started_ns ? std::min(now_ns - started_ns, motion_duration_ns) : 0;
      const auto phase = static_cast<float>(elapsed) / static_cast<float>(motion_duration_ns);

      return from + ((to - from) * phase * phase * (quadratic_weight - (cubic_weight * phase)));
    }
  };

  [[nodiscard]] inline std::optional<std::size_t> motion(NotificationId id, float y) noexcept {
    auto *const found = std::ranges::find(motions_, id, &Motion::id);
    if (found != motions_.end()) {
      return static_cast<std::size_t>(found - motions_.begin());
    }

    constexpr NotificationId invalid;
    auto *const vacant = std::ranges::find(motions_, invalid, &Motion::id);
    if (vacant == motions_.end()) {
      return std::nullopt;
    }

    *vacant = {.id = id, .from = y, .to = y};

    return static_cast<std::size_t>(vacant - motions_.begin());
  }

  std::array<Motion, NotificationCenter::capacity> motions_{};
};

}
}

// Interface: presentation/peek_labels.cppm
export {
namespace telar::gui {

struct PeekLabels {
  static constexpr std::size_t facts_bytes = 256;
  using Facts = BoundedText<facts_bytes>;

  template <Allocator Memory>
  [[nodiscard]] inline static std::string_view title(const Agent<Memory> &agent, const Worktree<Memory> *task) noexcept {
    if (task == nullptr) {
      return AgentCardLabels::title({}, agent.display_name);
    }

    return task->title.empty() ? std::string_view{task->branch} : std::string_view{task->title};
  }

  template <Allocator Memory>
  [[nodiscard]] inline static Facts facts(const Agent<Memory> &agent, const Worktree<Memory> *task) {
    Facts result;
    append(result, AgentCardLabels::title({}, agent.display_name));
    append(result, " · ");
    constexpr std::array statuses{std::string_view{"unknown"}, std::string_view{"working"}, std::string_view{"blocked"}, std::string_view{"ready"}, std::string_view{"failed"}, std::string_view{"done"}};
    const auto status = static_cast<std::size_t>(agent.status);
    append(result, statuses[status < statuses.size() ? status : 0]);
    if (task != nullptr) {
      append(result, "  \u2387 ");
      append(result, task->handle());
    }

    if (agent.plan_total != 0) {
      append(result, "  ");
      decimal(result, agent.plan_done);
      append(result, "/");
      decimal(result, agent.plan_total);
      append(result, " ");
      append(result, agent.plan_step);
    } else if (!agent.detail.empty()) {
      append(result, "  ");
      append(result, agent.detail);
    }

    return result;
  }

private:
  inline static void append(Facts &storage, std::string_view text) {
    storage.append(text.substr(0, facts_bytes - storage.view().size()));
  }

  inline static void decimal(Facts &storage, std::uint16_t value) {
    constexpr auto capacity = std::numeric_limits<std::uint16_t>::digits10 + 1;
    std::array<char, capacity> digits{};
    const auto result = std::to_chars(digits.data(), digits.data() + digits.size(), value);
    append(storage, {digits.data(), static_cast<std::size_t>(result.ptr - digits.data())});
  }
};

}
}

// Interface: presentation/workspace_window.cppm
export {
namespace telar::gui {

struct WorkspaceWindow {
  struct Selection {
    std::size_t count = 0;
    std::size_t active = 0;
  };

  std::size_t first = 0;
  std::size_t count = 0;
  std::size_t total = 0;

  [[nodiscard]] inline static WorkspaceWindow centered(Selection selection, std::size_t capacity) noexcept {
    const auto total = selection.count;
    const auto count = std::min(total, capacity);
    if (count == 0) {
      return {.total = total};
    }

    const auto active = std::min(selection.active, total - 1);
    const auto half = count / 2;
    const auto start = active > half ? active - half : 0;

    return {.first = std::min(start, total - count), .count = count, .total = total};
  }

  [[nodiscard]] inline std::optional<std::size_t> previous() const noexcept {
    return first == 0 ? std::nullopt : std::optional{first - 1};
  }

  [[nodiscard]] inline std::optional<std::size_t> next() const noexcept {
    const auto index = first + count;

    return index == total ? std::nullopt : std::optional{index};
  }
};

}
}

// Interface: presentation/workspace_rail_geometry.cppm
export {
namespace telar::gui {

struct WorkspaceRailGeometry {
  static constexpr float button_side = 36;
  static constexpr float button_gap = 10;
  static constexpr float inset = 12;
  static constexpr float counter_height = 20;
  static constexpr float edge_width = 1;

  WorkspaceWindow window;
  Rect list;
  Rect previous;
  Rect next;
  float side = 0;
  float gap = 0;
  float mark_top = 0;

  [[nodiscard]] inline static WorkspaceRailGeometry measure(Rect area, float ratio, WorkspaceWindow::Selection selection) noexcept {
    WorkspaceRailGeometry geometry;
    if (!std::isfinite(ratio) || ratio <= 0 || !std::isfinite(area.x) || !std::isfinite(area.y) || !std::isfinite(area.width) || !std::isfinite(area.height) || area.width <= edge_width || area.height <= 0) {
      return geometry;
    }

    geometry.side = std::min(button_side * ratio, area.width - edge_width);
    geometry.gap = button_gap * ratio;
    const auto vertical_inset = inset * ratio;
    const auto top = area.y + vertical_inset;
    auto remaining = area.y + area.height;
    remaining -= vertical_inset;
    remaining -= top;
    geometry.list = {.x = area.x + std::floor((area.width - edge_width - geometry.side) / 2), .y = top, .width = geometry.side, .height = std::max(0.0F, remaining)};
    if (geometry.list.height <= 0 || geometry.side <= 0) {
      return geometry;
    }

    const auto pitch = geometry.side + geometry.gap;
    const auto bounded_capacity = [total = selection.count](float available) {
      const auto count = std::max(0.0F, std::floor(available));

      return count >= static_cast<float>(total) ? total : static_cast<std::size_t>(count);
    };
    auto capacity = bounded_capacity((geometry.list.height + geometry.gap) / pitch);
    const auto counter = counter_height * ratio;
    const bool counters = capacity < selection.count && geometry.list.height >= geometry.side + (2 * (counter + geometry.gap));
    if (counters) {
      capacity = bounded_capacity((geometry.list.height - (2 * (counter + geometry.gap)) + geometry.gap) / pitch);
    }

    geometry.window = WorkspaceWindow::centered(selection, std::max(std::size_t{1}, capacity));
    geometry.mark_top = geometry.list.y;
    if (counters) {
      geometry.previous = {.x = geometry.list.x, .y = geometry.list.y, .width = geometry.side, .height = counter};
      geometry.mark_top += counter + geometry.gap;
      auto top = geometry.mark_top;
      for (std::size_t position = 0; position < geometry.window.count && top + geometry.side <= geometry.list.bottom(); ++position) {
        top += pitch;
      }

      geometry.next = {.x = geometry.list.x, .y = top, .width = geometry.side, .height = counter};
    }

    return geometry;
  }

  [[nodiscard]] inline Rect firstMark() const noexcept {
    const Rect bounds{.x = list.x, .y = mark_top, .width = side, .height = side};

    return window.count != 0 && bounds.bottom() <= list.bottom() ? bounds : Rect{};
  }

  [[nodiscard]] inline Rect nextMark(Rect current) const noexcept {
    current.y += side + gap;

    return current.bottom() <= list.bottom() ? current : Rect{};
  }

};

}
}
