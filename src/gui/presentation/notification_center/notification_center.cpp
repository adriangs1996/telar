module telar.gui.presentation.notification_center;

import std;
import telar.tbc;

import telar.base.text.utf8;
import telar.gui.foundation.core;
import telar.wire.vocabulary;

namespace telar::gui {

  NotificationItem NotificationItem::create(std::uint64_t now_ns, NotificationInput input) {
    NotificationItem item;

    item.level = input.level;
    item.target = input.target;
    item.transition_updated_ns = now_ns;
    item.expires_at_ns = deadlineAfter(deadlineAfter(now_ns, transition_duration_ns), input.duration_ns);
    copyText(item.title, input.title);
    copyText(item.message, input.message);
    if (input.link.size() <= max_notification_link_bytes) {
      item.link.assign(input.link);
    }

    return item;
  }

  bool NotificationItem::same(const NotificationItem& other) const noexcept {
    const auto same_target = target.kind == other.target.kind && (target.kind == NotificationTarget::Kind::none || target.id == other.target.id);

    return level == other.level && same_target && title.view() == other.title.view() && message.view() == other.message.view() && link.view() == other.link.view();
  }

  std::string_view NotificationItem::linkHost() const noexcept {
    return notificationLinkHost(link.view());
  }

  bool NotificationItem::clickable() const noexcept {
    return target.kind != NotificationTarget::Kind::none || !link.view().empty();
  }

  bool NotificationItem::beginExit(std::uint64_t now_ns) noexcept {
    if (phase == Phase::exiting) {
      return false;
    }

    if (phase == Phase::entering) {
      advanceEntering(now_ns);
    }

    phase = Phase::exiting;
    transition_updated_ns = now_ns;

    return true;
  }

  bool NotificationItem::advance(std::uint64_t now_ns) noexcept {
    bool changed = false;

    if (phase == Phase::entering) {
      changed = advanceEntering(now_ns);
    }

    if (phase == Phase::visible && now_ns >= expires_at_ns) {
      phase = Phase::exiting;
      transition_updated_ns = expires_at_ns;
      changed = true;
    }

    if (phase == Phase::exiting) {
      changed = advanceExiting(now_ns) || changed;
    }

    return changed;
  }

  std::uint64_t NotificationItem::nextDeadline(std::uint64_t now_ns, std::uint64_t frame_interval_ns) const noexcept {
    switch (phase) {
    case Phase::entering:
      return std::min(deadlineAfter(now_ns, frame_interval_ns), deadlineAfter(transition_updated_ns, transition_duration_ns - transition_position_ns));
    case Phase::visible:
      return expires_at_ns;
    case Phase::exiting:
      return std::min(deadlineAfter(now_ns, frame_interval_ns), deadlineAfter(transition_updated_ns, transition_position_ns));
    }

    return now_ns;
  }

  float NotificationItem::opacity() const noexcept {
    const auto position = static_cast<float>(transition_position_ns) / static_cast<float>(transition_duration_ns);

    return smoothstep(position);
  }

  float NotificationItem::opacity(std::uint64_t now_ns) const noexcept {
    auto sampled = *this;

    sampled.advance(now_ns);

    return sampled.opacity();
  }

  template <std::size_t Capacity>
  void NotificationItem::copyText(runtime::FixedText<Capacity>& destination, std::string_view text) {
    constexpr std::string_view invalid_text = "invalid notification text";
    const auto valid = inspectUtf8(text) == Utf8Validation::valid ? text : invalid_text;

    destination.assign(runtime::utf8Prefix(valid, Capacity));
  }

  bool NotificationItem::advanceEntering(std::uint64_t now_ns) noexcept {
    if (now_ns <= transition_updated_ns) {
      return false;
    }

    const auto previous = transition_position_ns;

    transition_position_ns = std::min(transition_duration_ns, deadlineAfter(previous, now_ns - transition_updated_ns));
    transition_updated_ns = now_ns;
    if (transition_position_ns == transition_duration_ns) {
      phase = Phase::visible;
    }

    return transition_position_ns != previous;
  }

  bool NotificationItem::advanceExiting(std::uint64_t now_ns) noexcept {
    if (now_ns <= transition_updated_ns) {
      return false;
    }

    const auto previous = transition_position_ns;

    transition_position_ns -= std::min(transition_position_ns, now_ns - transition_updated_ns);
    transition_updated_ns = now_ns;

    return transition_position_ns != previous;
  }

  NotificationCenter::NotificationCenter(std::uint64_t first_id) noexcept
      : next_id_(first_id) {}

  std::span<const NotificationItem> NotificationCenter::items() const noexcept {
    return std::span{items_}.first(count_);
  }

  const NotificationItem* NotificationCenter::find(NotificationId id) const noexcept {
    const auto current = items();
    const auto found = std::ranges::find(current, id, &NotificationItem::id);

    return found == current.end() ? nullptr : &*found;
  }

  NotificationId NotificationCenter::push(std::uint64_t now_ns, NotificationInput input) {
    auto item = NotificationItem::create(now_ns, input);

    for (auto& existing : std::span{items_}.first(count_)) {
      if (existing.phase == NotificationItem::Phase::exiting || !existing.same(item)) {
        continue;
      }

      const auto started = existing.phase == NotificationItem::Phase::entering ? NotificationItem::deadlineAfter(now_ns, NotificationItem::transition_duration_ns) : now_ns;

      existing.expires_at_ns = NotificationItem::deadlineAfter(started, input.duration_ns);

      return existing.id;
    }

    if (next_id_ == 0) {
      next_id_ = 1;
    }

    item.id = NotificationId{next_id_++};
    count_ = std::min(count_, capacity - 1);
    std::move_backward(items_.begin(), items_.begin() + static_cast<std::ptrdiff_t>(count_), items_.begin() + static_cast<std::ptrdiff_t>(count_ + 1));
    items_.front() = item;
    ++count_;

    return item.id;
  }

  bool NotificationCenter::advance(std::uint64_t now_ns) noexcept {
    bool changed = false;
    std::size_t index = 0;

    while (index < count_) {
      auto& item = items_[index];

      changed = item.advance(now_ns) || changed;
      if (item.phase == NotificationItem::Phase::exiting && item.transition_position_ns == 0) {
        const auto tail = std::span{items_}.subspan(index + 1, count_ - index - 1);

        std::ranges::move(tail, items_.begin() + static_cast<std::ptrdiff_t>(index));
        --count_;
        changed = true;
      } else {
        ++index;
      }
    }

    return changed;
  }

  bool NotificationCenter::dismiss(NotificationId id, std::uint64_t now_ns) noexcept {
    for (auto& item : std::span{items_}.first(count_)) {
      if (item.id == id) {
        return item.beginExit(now_ns);
      }
    }

    return false;
  }

  std::optional<NotificationTarget> NotificationCenter::activate(NotificationId id, std::uint64_t now_ns) noexcept {
    for (auto& item : std::span{items_}.first(count_)) {
      if (item.id == id && item.beginExit(now_ns)) {
        return item.target;
      }
    }

    return std::nullopt;
  }

  std::optional<std::uint64_t> NotificationCenter::nextDeadline(std::uint64_t now_ns, std::uint64_t frame_interval_ns) const {
    if (frame_interval_ns == 0) {
      throw std::invalid_argument{"InvalidNotificationFrameInterval"};
    }

    if (count_ == 0) {
      return std::nullopt;
    }

    auto deadline = std::numeric_limits<std::uint64_t>::max();

    for (const auto& item : items()) {
      deadline = std::min(deadline, item.nextDeadline(now_ns, frame_interval_ns));
    }

    return deadline;
  }

  tbc::view<std::optional<NotificationInput>, tbc::lt::a> AgentAlerts::input(const AgentStatusChange& change, std::string_view label, tbc::view<Message&, tbc::lt::a> message) {
    if (!alertable(change)) {
      return std::nullopt;
    }

    const auto text = formatMessage(change, label, message);

    return NotificationInput{.level = level(change.current), .target = {.kind = NotificationTarget::Kind::pane, .id = change.pane_id}, .title = title(change.current), .message = text, .link = {}, .duration_ns = duration(change.current)};
  }

  tbc::view<std::string_view, tbc::lt::a> AgentAlerts::formatMessage(const AgentStatusChange& change, std::string_view label, tbc::view<Message&, tbc::lt::a> message) {
    message.truncate(0);
    try {
      message.append(label);
      message.append(" in pane ");
      message.appendDecimal(change.pane_index);
      message.append(" is ");
      message.append(statusName(change.current));

      return message.view();
    } catch (const std::length_error&) {
      return "Agent status changed";
    }
  }

  void AgentAlerts::add(AgentStatus status) noexcept {
    switch (status) {
    case AgentStatus::blocked:
      ++blocked_;
      break;
    case AgentStatus::done:
      ++done_;
      break;
    case AgentStatus::failed:
      ++failed_;
      break;
    default:
      break;
    }
  }

  tbc::view<std::optional<NotificationInput>, tbc::lt::a> AgentAlerts::summary(tbc::view<Message&, tbc::lt::a> message) const {
    const auto total = blocked_ + done_ + failed_;
    if (total == 0) {
      return std::nullopt;
    }

    message.appendDecimal(total);
    message.append(" more agents:");
    appendCount(message, blocked_, AgentStatus::blocked, false);
    appendCount(message, done_, AgentStatus::done, blocked_ != 0);
    appendCount(message, failed_, AgentStatus::failed, blocked_ + done_ != 0);
    auto severity = AgentStatus::done;

    if (blocked_ != 0) {
      severity = AgentStatus::blocked;
    }

    if (failed_ != 0) {
      severity = AgentStatus::failed;
    }

    return NotificationInput{.level = level(severity), .title = "More agents changed", .message = message.view(), .link = {}, .duration_ns = duration(severity)};
  }

  void AgentAlerts::appendCount(Message& message, std::size_t count, AgentStatus status, bool separated) {
    if (count == 0) {
      return;
    }

    message.append(separated ? ", " : " ");
    message.appendDecimal(count);
    message.append(" ");
    message.append(statusName(status));
  }

}
