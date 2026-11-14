module telar.gui.presentation.notification_stack;

import std;
import telar.tbc;

import telar.gui.core.primitives;
import telar.wire.vocabulary;

namespace telar::gui {

  tbc::view<std::string_view, tbc::lt::a> AgentCardLabels::title(tbc::view<std::string_view, tbc::lt::a> session, tbc::view<std::string_view, tbc::lt::a> display_name) noexcept {
    if (!session.empty()) {
      return session;
    }

    return display_name.empty() ? generic_name : display_name;
  }

  std::string_view AgentCardLabels::providerGlyph(AgentProvider provider, std::string_view custom) noexcept {
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

  tbc::view<std::string_view, tbc::lt::a> AgentCardLabels::project(tbc::view<std::string_view, tbc::lt::a> workspace, tbc::view<std::string_view, tbc::lt::a> machine, bool coordinator, tbc::view<Project&, tbc::lt::a> storage) {
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
    } catch (const std::length_error&) {
      return machine.empty() ? workspace : machine;
    }
  }

  void NotificationActionLabel::format(std::string_view host, bool truncated, Buffer& buffer) {
    buffer.truncate(0);
    buffer.append(truncated ? "Open …" : "Open ");
    buffer.append(host);
    buffer.append(" ↗");
  }

  float NotificationMetrics::px(float value) const noexcept {
    return value * ratio;
  }

  float NotificationMetrics::height(std::size_t body_lines, bool clickable) const noexcept {
    auto height = px(vertical_padding) + title_row;

    if (body_lines > 0) {
      height += px(body_gap) + (static_cast<float>(body_lines) * body_row);
    }

    if (clickable) {
      height += px(action_gap) + small_row;
    }

    return std::max(height, px(minimum_card_height));
  }

  Rect NotificationCardGeometry::icon() const noexcept {
    return {.x = bounds.x + metrics.px(NotificationMetrics::card_padding), .y = bounds.y + metrics.px(NotificationMetrics::card_padding), .width = metrics.px(NotificationMetrics::icon_side), .height = metrics.px(NotificationMetrics::icon_side)};
  }

  Rect NotificationCardGeometry::title() const noexcept {
    return {.x = textLeft(), .y = bounds.y + metrics.px(NotificationMetrics::card_padding), .width = bounds.width - metrics.px(NotificationMetrics::title_insets), .height = metrics.title_row};
  }

  Rect NotificationCardGeometry::body(std::size_t row) const noexcept {
    auto y = bounds.y + metrics.px(NotificationMetrics::body_top) + metrics.title_row;

    for (std::size_t index = 0; index < row; ++index) {
      y += metrics.body_row;
    }

    return {.x = textLeft(), .y = y, .width = bodyWidth(), .height = metrics.body_row};
  }

  Rect NotificationCardGeometry::action() const noexcept {
    return {.x = textLeft(), .y = bounds.y + bounds.height - metrics.px(NotificationMetrics::card_padding) - metrics.small_row, .width = bodyWidth(), .height = metrics.small_row};
  }

  Rect NotificationCardGeometry::close() const noexcept {
    return {.x = bounds.x + bounds.width - metrics.px(NotificationMetrics::close_right), .y = bounds.y + metrics.px(NotificationMetrics::close_top), .width = metrics.px(NotificationMetrics::close_side), .height = metrics.px(NotificationMetrics::close_side)};
  }

  Rect NotificationCardGeometry::actionUnderline(float line_height, float advance) const noexcept {
    const auto row = action();
    const auto top = std::floor(row.y + ((row.height - line_height) / 2));

    return {.x = row.x, .y = top + line_height - NotificationMetrics::underline_bottom, .width = std::min(row.width, advance), .height = NotificationMetrics::underline_height};
  }

  float NotificationCardGeometry::bodyWidth() const noexcept {
    return bounds.width - metrics.px(NotificationMetrics::text_insets);
  }

  float NotificationCardGeometry::textLeft() const noexcept {
    return bounds.x + metrics.px(NotificationMetrics::text_left);
  }

  std::span<const NotificationPlacement> NotificationStack::Cards::items() const noexcept {
    return std::span{placements}.first(count);
  }

  std::optional<std::uint64_t> NotificationStack::nextDeadline(std::uint64_t now_ns, std::uint64_t interval_ns) const noexcept {
    std::optional<std::uint64_t> earliest;

    for (const auto& motion : motions_) {
      if (motion.id.value == 0 || motion.from == motion.to || (now_ns >= motion.started_ns && now_ns - motion.started_ns >= motion_duration_ns)) {
        continue;
      }

      const auto deadline = std::min(NotificationItem::deadlineAfter(now_ns, interval_ns), NotificationItem::deadlineAfter(motion.started_ns, motion_duration_ns));

      earliest = earliest ? std::min(*earliest, deadline) : deadline;
    }

    return earliest;
  }

  float NotificationStack::Motion::position(float target, const NotificationStackRequest& frame) noexcept {
    const auto now_ns = frame.now_ns;

    if (to != target) {
      from = value(now_ns);
      to = target;
      started_ns = now_ns;
    }

    return value(now_ns);
  }

  float NotificationStack::Motion::value(std::uint64_t now_ns) const noexcept {
    constexpr float quadratic_weight = 3;
    constexpr float cubic_weight = 2;
    const auto elapsed = now_ns >= started_ns ? std::min(now_ns - started_ns, motion_duration_ns) : 0;
    const auto phase = static_cast<float>(elapsed) / static_cast<float>(motion_duration_ns);

    return from + ((to - from) * phase * phase * (quadratic_weight - (cubic_weight * phase)));
  }

  std::optional<std::size_t> NotificationStack::motion(NotificationId id, float y) noexcept {
    auto* const found = std::ranges::find(motions_, id, &Motion::id);
    if (found != motions_.end()) {
      return static_cast<std::size_t>(found - motions_.begin());
    }

    constexpr NotificationId invalid;
    auto* const vacant = std::ranges::find(motions_, invalid, &Motion::id);
    if (vacant == motions_.end()) {
      return std::nullopt;
    }

    *vacant = {.id = id, .from = y, .to = y};

    return static_cast<std::size_t>(vacant - motions_.begin());
  }

  template <Allocator Memory>
  tbc::view<std::string_view, tbc::lt::a> PeekLabels::title(tbc::view<const Agent<Memory>&, tbc::lt::a> agent, tbc::view<const Worktree<Memory>*, tbc::lt::a> task) noexcept {
    if (task == nullptr) {
      return AgentCardLabels::title({}, agent.display_name);
    }

    return task->title.empty() ? std::string_view{task->branch} : std::string_view{task->title};
  }

  template <Allocator Memory>
  PeekLabels::Facts PeekLabels::facts(const Agent<Memory>& agent, const Worktree<Memory>* task) {
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

  void PeekLabels::append(Facts& storage, std::string_view text) {
    storage.append(text.substr(0, facts_bytes - storage.view().size()));
  }

  void PeekLabels::decimal(Facts& storage, std::uint16_t value) {
    constexpr auto capacity = std::numeric_limits<std::uint16_t>::digits10 + 1;
    std::array<char, capacity> digits{};
    const auto result = std::to_chars(digits.data(), digits.data() + digits.size(), value);

    append(storage, {digits.data(), static_cast<std::size_t>(result.ptr - digits.data())});
  }

  template tbc::view<std::string_view, tbc::lt::a> PeekLabels::title<Memory>(tbc::view<const Agent<Memory>&, tbc::lt::a> agent, tbc::view<const Worktree<Memory>*, tbc::lt::a> task) noexcept;
  template tbc::view<std::string_view, tbc::lt::a> PeekLabels::title<ConcurrentMemory>(tbc::view<const Agent<ConcurrentMemory>&, tbc::lt::a> agent, tbc::view<const Worktree<ConcurrentMemory>*, tbc::lt::a> task) noexcept;
  template PeekLabels::Facts PeekLabels::facts<Memory>(const Agent<Memory>& agent, const Worktree<Memory>* task);
  template PeekLabels::Facts PeekLabels::facts<ConcurrentMemory>(const Agent<ConcurrentMemory>& agent, const Worktree<ConcurrentMemory>* task);

}
