module;
#include "tbc/view.hpp"

export module telar.gui.presentation.notification_center;

import std;

export import telar.gui.core.unicode_scalar;
export import telar.gui.model.records;
export import telar.gui.text.json_unsigned_integer;
import telar.base.diagnostics;
import telar.base.memory.containers;
import telar.gui.core.primitives;
import telar.wire.vocabulary;

// Interface: application/notification_item.cppm
export {
  namespace telar::gui {

    struct NotificationId {
      std::uint64_t value = 0;

      bool operator==(const NotificationId&) const noexcept = default;
    };

    struct NotificationInput {
      static constexpr std::uint64_t nanoseconds_per_millisecond = 1'000'000;
      static constexpr std::uint64_t default_duration_ns = default_notification_duration_ms * nanoseconds_per_millisecond;
      NotificationLevel level = NotificationLevel::info;
      NotificationTarget target{};
      std::string_view title;
      std::string_view message;
      std::string_view link;
      std::uint64_t duration_ns = default_duration_ns;
    };

    struct NotificationItem {
      enum class Phase : std::uint8_t {
        entering,
        visible,
        exiting,
      };

      static constexpr std::uint64_t transition_duration_ns = 200'000'000;
      NotificationId id{};
      NotificationLevel level = NotificationLevel::info;
      NotificationTarget target{};
      runtime::FixedText<max_notification_title_bytes> title;
      runtime::FixedText<max_notification_message_bytes> message;
      runtime::FixedText<max_notification_link_bytes> link;
      Phase phase = Phase::entering;
      std::uint64_t transition_position_ns = 0;
      std::uint64_t transition_updated_ns = 0;
      std::uint64_t expires_at_ns = 0;

      [[nodiscard]] static constexpr std::uint64_t deadlineAfter(std::uint64_t now_ns, std::uint64_t duration_ns) noexcept {
        return now_ns + std::min(std::numeric_limits<std::uint64_t>::max() - now_ns, duration_ns);
      }

      [[nodiscard]] inline static NotificationItem create(std::uint64_t now_ns, NotificationInput input) {
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

      [[nodiscard]] inline bool same(const NotificationItem& other) const noexcept {
        const auto same_target = target.kind == other.target.kind && (target.kind == NotificationTarget::Kind::none || target.id == other.target.id);

        return level == other.level && same_target && title.view() == other.title.view() && message.view() == other.message.view() && link.view() == other.link.view();
      }

      [[nodiscard]] inline std::string_view linkHost() const noexcept {
        return notificationLinkHost(link.view());
      }

      [[nodiscard]] inline bool clickable() const noexcept {
        return target.kind != NotificationTarget::Kind::none || !link.view().empty();
      }

      inline bool beginExit(std::uint64_t now_ns) noexcept {
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

      inline bool advance(std::uint64_t now_ns) noexcept {
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

      [[nodiscard]] inline std::uint64_t nextDeadline(std::uint64_t now_ns, std::uint64_t frame_interval_ns) const noexcept {
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

      [[nodiscard]] inline float opacity() const noexcept {
        const auto position = static_cast<float>(transition_position_ns) / static_cast<float>(transition_duration_ns);

        return smoothstep(position);
      }

      [[nodiscard]] inline float opacity(std::uint64_t now_ns) const noexcept {
        auto sampled = *this;

        sampled.advance(now_ns);

        return sampled.opacity();
      }

    private:
      template <std::size_t Capacity>
      inline static void copyText(runtime::FixedText<Capacity>& destination, std::string_view text) {
        constexpr std::string_view invalid_text = "invalid notification text";
        const auto valid = inspectUtf8(text) == Utf8Validation::valid ? text : invalid_text;

        destination.assign(runtime::utf8Prefix(valid, Capacity));
      }

      inline bool advanceEntering(std::uint64_t now_ns) noexcept {
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

      inline bool advanceExiting(std::uint64_t now_ns) noexcept {
        if (now_ns <= transition_updated_ns) {
          return false;
        }

        const auto previous = transition_position_ns;

        transition_position_ns -= std::min(transition_position_ns, now_ns - transition_updated_ns);
        transition_updated_ns = now_ns;

        return transition_position_ns != previous;
      }
    };

  }
}

// Interface: application/notification_center.cppm
export {
  namespace telar::gui {

    class NotificationCenter {
    public:
      static constexpr std::size_t capacity = 4;

      inline explicit NotificationCenter(std::uint64_t first_id = 1) noexcept
          : next_id_(first_id) {}

      [[nodiscard]] inline std::span<const NotificationItem> items() const noexcept {
        return std::span{items_}.first(count_);
      }

      [[nodiscard]] inline const NotificationItem* find(NotificationId id) const noexcept {
        const auto current = items();
        const auto found = std::ranges::find(current, id, &NotificationItem::id);

        return found == current.end() ? nullptr : &*found;
      }

      inline NotificationId push(std::uint64_t now_ns, NotificationInput input) {
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

      inline bool advance(std::uint64_t now_ns) noexcept {
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

      inline bool dismiss(NotificationId id, std::uint64_t now_ns) noexcept {
        for (auto& item : std::span{items_}.first(count_)) {
          if (item.id == id) {
            return item.beginExit(now_ns);
          }
        }

        return false;
      }

      [[nodiscard]] inline std::optional<NotificationTarget> activate(NotificationId id, std::uint64_t now_ns) noexcept {
        for (auto& item : std::span{items_}.first(count_)) {
          if (item.id == id && item.beginExit(now_ns)) {
            return item.target;
          }
        }

        return std::nullopt;
      }

      [[nodiscard]] inline std::optional<std::uint64_t> nextDeadline(std::uint64_t now_ns, std::uint64_t frame_interval_ns) const {
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

    private:
      std::array<NotificationItem, capacity> items_;
      std::size_t count_ = 0;
      std::uint64_t next_id_;
    };

  }
}

// Interface: application/agent_alerts.cppm
export {
  namespace telar::gui {

    template <typename Resolve>
    concept AgentAlertLabel = requires(Resolve& resolve, AgentStatusChange change) {
      { resolve(change) } -> std::convertible_to<std::string_view>;
    };

    template <typename Publish>
    concept NotificationPublisher = requires(Publish& publish, NotificationInput input) {
      publish(input);
    };

    class AgentAlerts {
    public:
      static constexpr std::size_t message_capacity = 96;
      static constexpr std::uint64_t failed_duration_ns = 7'000'000'000;
      using Message = BoundedText<message_capacity>;

      [[nodiscard]] static constexpr bool alertable(const AgentStatusChange& change) noexcept {
        return change.current == AgentStatus::blocked || change.current == AgentStatus::done || change.current == AgentStatus::failed;
      }

      // The input's message is written into the message, region `a`; its title is a literal.
      [[nodiscard]] inline static tbc::view<std::optional<NotificationInput>, tbc::lt::a> input(const AgentStatusChange& change, std::string_view label, tbc::view<Message&, tbc::lt::a> message) {
        if (!alertable(change)) {
          return std::nullopt;
        }

        const auto text = formatMessage(change, label, message);

        return NotificationInput{.level = level(change.current), .target = {.kind = NotificationTarget::Kind::pane, .id = change.pane_id}, .title = title(change.current), .message = text, .link = {}, .duration_ns = duration(change.current)};
      }

      template <AgentAlertLabel Resolve, NotificationPublisher Publish>
      inline static std::size_t publish(std::span<const AgentStatusChange> changes, Resolve resolve, Publish publish_notification) {
        const auto count = static_cast<std::size_t>(std::ranges::count_if(changes, alertable));
        const auto individual = count > NotificationCenter::capacity ? NotificationCenter::capacity - 1 : count;
        std::size_t published = 0;
        AgentAlerts folded;

        for (const auto& change : changes) {
          if (!alertable(change)) {
            continue;
          }

          if (published == individual) {
            folded.add(change.current);
            continue;
          }

          Message message;
          if (const auto alert = input(change, resolve(change), message)) {
            publish_notification(*alert);
            ++published;
          }
        }

        Message message;
        if (const auto summary = folded.summary(message)) {
          publish_notification(*summary);
          ++published;
        }

        return published;
      }

    private:
      [[nodiscard]] static constexpr std::string_view statusName(AgentStatus status) noexcept {
        switch (status) {
        case AgentStatus::blocked:
          return "waiting for input";
        case AgentStatus::done:
          return "done";
        case AgentStatus::failed:
          return "failed";
        case AgentStatus::ready:
          return "ready";
        default:
          return "active";
        }
      }

      [[nodiscard]] static constexpr std::string_view title(AgentStatus status) noexcept {
        switch (status) {
        case AgentStatus::blocked:
          return "Agent needs input";
        case AgentStatus::done:
          return "Agent done";
        case AgentStatus::failed:
          return "Agent failed";
        default:
          return {};
        }
      }

      [[nodiscard]] static constexpr NotificationLevel level(AgentStatus status) noexcept {
        switch (status) {
        case AgentStatus::blocked:
          return NotificationLevel::warning;
        case AgentStatus::failed:
          return NotificationLevel::failure;
        default:
          return NotificationLevel::success;
        }
      }

      [[nodiscard]] static constexpr std::uint64_t duration(AgentStatus status) noexcept {
        return status == AgentStatus::failed ? failed_duration_ns : NotificationInput::default_duration_ns;
      }

      [[nodiscard]] inline static tbc::view<std::string_view, tbc::lt::a> formatMessage(const AgentStatusChange& change, std::string_view label, tbc::view<Message&, tbc::lt::a> message) {
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

      inline void add(AgentStatus status) noexcept {
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

      [[nodiscard]] inline tbc::view<std::optional<NotificationInput>, tbc::lt::a> summary(tbc::view<Message&, tbc::lt::a> message) const {
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

      inline static void appendCount(Message& message, std::size_t count, AgentStatus status, bool separated) {
        if (count == 0) {
          return;
        }

        message.append(separated ? ", " : " ");
        message.appendDecimal(count);
        message.append(" ");
        message.append(statusName(status));
      }

      std::size_t blocked_ = 0;
      std::size_t done_ = 0;
      std::size_t failed_ = 0;
    };

  }
}
