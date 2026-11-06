module;

#include "telar_client/serializers/telar_messages.hpp"
#include <cstdint>


#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include <algorithm>
#include <cstddef>
#include <limits>
#include <string_view>


#include <array>
#include <optional>
#include <span>
#include <stdexcept>


#include <charconv>
#include <concepts>
#include <cstring>
#include <system_error>


#include "../core/terminal_size.hpp"
#include "../core/memory.hpp"
#include <atomic>
#include <exception>
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_config/graphics/limits.hpp"
#include <utility>
#include <variant>
#include "../terminal/screen.hpp"

export module telar.gui.application.workspace_replica;

export import telar.gui.core.unicode_scalar;


export import telar.gui.text.json_unsigned_integer;


export import telar.gui.graphics.texture_cache;
export import telar.gui.application.sound_playback;
export import telar.gui.presentation.application_mark;

// Interface: application/agent_status_change.cppm
export {
namespace telar::gui {

struct AgentStatusChange {
  std::uint64_t pane_id = 0;
  std::uint64_t pane_generation = 0;
  std::uint16_t pane_index = 0;
  AgentProvider provider = AgentProvider::unknown;
  AgentStatus previous = AgentStatus::unknown;
  AgentStatus current = AgentStatus::unknown;
};

}
}

// Interface: application/notification_item.cppm
export {
namespace telar::gui {

struct NotificationId {
  std::uint64_t value = 0;

  bool operator==(const NotificationId &) const noexcept = default;
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

  [[nodiscard]] inline bool same(const NotificationItem &other) const noexcept {
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
  inline static void copyText(runtime::FixedText<Capacity> &destination, std::string_view text) {
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

  [[nodiscard]] inline const NotificationItem *find(NotificationId id) const noexcept {
    const auto current = items();
    const auto found = std::ranges::find(current, id, &NotificationItem::id);

    return found == current.end() ? nullptr : &*found;
  }

  inline NotificationId push(std::uint64_t now_ns, NotificationInput input) {
    auto item = NotificationItem::create(now_ns, input);
    for (auto &existing : std::span{items_}.first(count_)) {
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
      auto &item = items_[index];
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
    for (auto &item : std::span{items_}.first(count_)) {
      if (item.id == id) {
        return item.beginExit(now_ns);
      }
    }

    return false;
  }

  [[nodiscard]] inline std::optional<NotificationTarget> activate(NotificationId id, std::uint64_t now_ns) noexcept {
    for (auto &item : std::span{items_}.first(count_)) {
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
    for (const auto &item : items()) {
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
concept AgentAlertLabel = requires(Resolve &resolve, AgentStatusChange change) {
  { resolve(change) } -> std::convertible_to<std::string_view>;
};

template <typename Publish>
concept NotificationPublisher = requires(Publish &publish, NotificationInput input) {
  publish(input);
};

class AgentAlerts {
public:
  static constexpr std::size_t message_capacity = 96;
  static constexpr std::uint64_t failed_duration_ns = 7'000'000'000;
  using Message = BoundedText<message_capacity>;

  [[nodiscard]] static constexpr bool alertable(const AgentStatusChange &change) noexcept {
    return change.current == AgentStatus::blocked || change.current == AgentStatus::done || change.current == AgentStatus::failed;
  }

  [[nodiscard]] inline static std::optional<NotificationInput> input(const AgentStatusChange &change, std::string_view label, Message &message) {
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
    for (const auto &change : changes) {
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

  [[nodiscard]] inline static std::string_view formatMessage(const AgentStatusChange &change, std::string_view label, Message &message) {
    message.truncate(0);
    try {
      message.append(label);
      message.append(" in pane ");
      message.appendDecimal(change.pane_index);
      message.append(" is ");
      message.append(statusName(change.current));

      return message.view();
    } catch (const std::length_error &) {
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

  [[nodiscard]] inline std::optional<NotificationInput> summary(Message &message) const {
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

  inline static void appendCount(Message &message, std::size_t count, AgentStatus status, bool separated) {
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

// Interface: application/records.cppm
export {
namespace telar::gui {

enum class PaneInputSource : std::uint8_t {
  keyboard,
  key_release,
  mouse,
  terminal_report,
};

enum class ScrollDirection : std::uint8_t {
  up,
  down,
};

enum class TabCreationOutcome : std::uint8_t {
  unavailable,
  requested,
  busy,
};

struct WorkspaceDraft {
  std::string_view name;
  std::string_view path;
  bool create_directory = false;
};

struct PaneScrollDelta {
  std::uint64_t pane_id = 0;
  std::int64_t rows = 0;
};

template <Allocator Memory>
struct Pane {
  inline explicit Pane(Memory &memory, std::uint64_t identity, GraphicsBudget &budget)
      : id(identity),
        screen(memory),
        graphics(memory, budget),
        title(AllocatorRef<char, Memory>{memory}),
        cwd(AllocatorRef<char, Memory>{memory}),
        foreground(AllocatorRef<char, Memory>{memory}) {}

  std::uint64_t id;
  std::uint64_t generation = 0;
  std::uint64_t attachment_generation = 0;
  TabLocation location;
  Screen<Memory> screen;
  GraphicsStore<Memory> graphics;
  String<Memory> title;
  String<Memory> cwd;
  String<Memory> foreground;
  TerminalSize size = default_terminal_size;
  bool attached = false;
  bool attaching = false;
  bool exited = false;
  bool snapshot_requested = false;
  std::uint64_t acknowledged_frame = 0;
  PaneProgressState progress_state = PaneProgressState::remove;
  std::optional<Byte> progress_percent;
};

template <Allocator Memory>
struct Tab {
  inline explicit Tab(Memory &memory, TabLocation identity)
      : location(identity),
        label(AllocatorRef<char, Memory>{memory}),
        foreground(AllocatorRef<char, Memory>{memory}) {}

  [[nodiscard]] inline std::string_view applicationName(const Pane<Memory> *pane) const noexcept {
    constexpr std::string_view fallback = "shell";
    if (pane != nullptr) {
      if (!pane->foreground.empty()) {
        return pane->foreground;
      }

      if (pane->id != foreground_pane) {
        return fallback;
      }
    }

    return foreground.empty() ? fallback : std::string_view{foreground};
  }

  inline bool observeForeground(PaneForeground report) {
    if (foreground_pane == report.pane_id && foreground == report.name) {
      return false;
    }

    foreground = report.name;
    foreground_pane = report.pane_id;

    return true;
  }

  inline bool observeForegrounds(std::span<const PaneForeground> names) {
    if (names.empty()) {
      return false;
    }

    auto selected = names.front();
    for (const auto name : names) {
      if (name.pane_id == focused_pane) {
        selected = name;
      }
    }

    return observeForeground(selected);
  }

  TabLocation location;
  String<Memory> label;
  String<Memory> foreground;
  PaneLayout layout;
  std::uint64_t focused_pane = 0;
  std::uint64_t foreground_pane = 0;
  std::uint16_t position = 0;
  bool fullscreen = false;
  bool loaded = false;
  bool loading = false;
  bool workspace_active = false;
};

template <Allocator Memory>
struct Workspace {
  inline explicit Workspace(Memory &memory, WorkspaceLocation identity = {})
      : location(identity),
        name(AllocatorRef<char, Memory>{memory}),
        path(AllocatorRef<char, Memory>{memory}),
        branch(AllocatorRef<char, Memory>{memory}) {}

  WorkspaceLocation location;
  String<Memory> name;
  String<Memory> path;
  String<Memory> branch;
  bool dirty = false;
  std::uint16_t tab_count = 0;
};

template <Allocator Memory>
struct Worktree {
  static constexpr std::size_t retained_path_bytes = 256;

  inline explicit Worktree(Memory &memory)
      : path(AllocatorRef<char, Memory>{memory}),
        branch(AllocatorRef<char, Memory>{memory}),
        base(AllocatorRef<char, Memory>{memory}),
        title(AllocatorRef<char, Memory>{memory}),
        command_label(AllocatorRef<char, Memory>{memory}) {}

  [[nodiscard]] inline std::string_view displayName() const noexcept {
    return title.empty() ? std::string_view{branch} : std::string_view{title};
  }

  [[nodiscard]] inline std::string_view handle() const noexcept {
    std::string_view name{branch};
    for (const auto prefix : {std::string_view{"worktree-"}, std::string_view{"worktree/"}}) {
      if (name.starts_with(prefix) && name.size() > prefix.size()) {
        name.remove_prefix(prefix.size());

        return name;
      }
    }

    return name;
  }

  std::uint64_t id = 0;
  std::uint64_t source = 0;
  std::optional<std::uint64_t> workspace;
  std::optional<std::uint64_t> created_by;
  std::optional<CoordinatorReference> coordinator;
  WorktreeState state = WorktreeState::active;
  String<Memory> path;
  String<Memory> branch;
  String<Memory> base;
  String<Memory> title;
  String<Memory> command_label;
  std::uint32_t diff_added = 0;
  std::uint32_t diff_removed = 0;
  std::uint32_t diff_files = 0;
  std::uint32_t commits_ahead = 0;
  CommandState command_state = CommandState::none;
  std::int32_t command_exit = 0;
};

template <Allocator Memory>
struct Agent {
  inline explicit Agent(Memory &memory)
      : title(AllocatorRef<char, Memory>{memory}),
        provider_name(AllocatorRef<char, Memory>{memory}),
        workspace_label(AllocatorRef<char, Memory>{memory}),
        display_name(AllocatorRef<char, Memory>{memory}),
        icon(AllocatorRef<char, Memory>{memory}),
        detail(AllocatorRef<char, Memory>{memory}),
        plan_step(AllocatorRef<char, Memory>{memory}),
        final_message(AllocatorRef<char, Memory>{memory}) {}

  [[nodiscard]] inline std::string_view finalLine() const noexcept {
    std::string_view remaining{final_message};
    while (!remaining.empty()) {
      const auto end = remaining.find('\n');
      auto line = remaining;
      line.remove_suffix(line.size() - std::min(end, line.size()));
      const auto first = line.find_first_not_of(" \t");
      if (first != std::string_view::npos) {
        line.remove_suffix(line.size() - line.find_last_not_of(" \t") - 1);
        line.remove_prefix(first);

        return line;
      }

      if (end == std::string_view::npos) {
        break;
      }

      remaining.remove_prefix(end + 1);
    }

    return {};
  }

  std::uint64_t pane_id = 0;
  std::uint64_t pane_generation = 0;
  std::uint16_t pane_index = 0;
  decltype(AgentSnapshotEntry::session_id) session_id{};
  std::uint64_t work_tree = 0;
  TabLocation location;
  AgentStatus status{};
  AgentBlockedReason blocked_reason = AgentBlockedReason::none;
  AgentProvider provider_kind = AgentProvider::unknown;
  AgentAttachmentMarkers attachments = AgentAttachmentMarkers::none;
  AgentTitleState title_state = AgentTitleState::placeholder;
  String<Memory> title;
  String<Memory> provider_name;
  String<Memory> workspace_label;
  String<Memory> display_name;
  String<Memory> icon;
  String<Memory> detail;
  String<Memory> plan_step;
  String<Memory> final_message;
  std::uint16_t plan_done = 0;
  std::uint16_t plan_total = 0;
  std::uint32_t status_age_s = 0;
  StatusAge status_clock;
};

}
}

// Interface: application/agent_replica.cppm
export {
namespace telar::gui {

template <Allocator Memory>
class AgentReplica {
public:
  static constexpr std::size_t capacity = 64;

  inline explicit AgentReplica(Memory &memory)
      : memory_(memory),
        entries_(AllocatorRef<Agent<Memory>, Memory>{memory}),
        staging_(AllocatorRef<Agent<Memory>, Memory>{memory}) {}

  [[nodiscard]] inline const auto &entries() const noexcept {
    return entries_;
  }

  [[nodiscard]] inline auto begin() const noexcept {
    return entries_.begin();
  }

  [[nodiscard]] inline auto end() const noexcept {
    return entries_.end();
  }

  [[nodiscard]] inline std::uint64_t revision() const noexcept {
    return revision_;
  }

  [[nodiscard]] inline std::span<const AgentStatusChange> statusChanges() const noexcept {
    return std::span{status_changes_}.first(status_change_count_);
  }

  inline void resetSource() noexcept {
    revision_ = 0;
    now_ns_ = 0;
    retain_clocks_ = false;
    status_change_count_ = 0;
  }

  inline bool apply(const AgentSnapshot &snapshot, std::uint64_t now_ns) {
    if (snapshot.revision <= revision_) {
      return false;
    }

    if (snapshot.entries.size() > capacity) {
      throw std::length_error{"TooManyAgents"};
    }

    validate(snapshot);
    prepareStaging(snapshot.entries.size());
    std::array<AgentStatusChange, capacity> status_changes;
    std::size_t status_change_count = 0;
    const auto sample_ns = std::max(now_ns_, now_ns);
    for (std::size_t index = 0; index < snapshot.entries.size(); ++index) {
      const auto &entry = snapshot.entries[index];
      auto &agent = staging_[index];
      assign(agent, entry);
      const auto previous = std::ranges::find_if(entries_, [&](const auto &candidate) {
        return candidate.pane_id == entry.pane_id && candidate.pane_generation == entry.pane_generation;
      });
      agent.status_clock = retain_clocks_ && previous != entries_.end() ? previous->status_clock : StatusAge{};
      agent.status_clock.observe({.pane_id = agent.pane_id, .pane_generation = agent.pane_generation, .status = agent.status, .provider = agent.provider_kind, .reported_seconds = agent.status_age_s}, sample_ns);

      if (retain_clocks_ && previous != entries_.end() && previous->status != agent.status) {
        status_changes[status_change_count++] = {.pane_id = agent.pane_id, .pane_generation = agent.pane_generation, .pane_index = agent.pane_index, .provider = agent.provider_kind, .previous = previous->status, .current = agent.status};
      }
    }

    entries_.swap(staging_);
    std::ranges::copy(std::span{status_changes}.first(status_change_count), status_changes_.begin());
    status_change_count_ = status_change_count;
    revision_ = snapshot.revision;
    now_ns_ = sample_ns;
    retain_clocks_ = true;

    return true;
  }

private:
  inline static void validate(const AgentSnapshot &snapshot) {
    for (std::size_t index = 0; index < snapshot.entries.size(); ++index) {
      const auto &entry = snapshot.entries[index];
      BodySchema<AgentSnapshotEntry>::validate(entry);
      for (const auto &previous : snapshot.entries.first(index)) {
        if (previous.pane_id == entry.pane_id && previous.pane_generation == entry.pane_generation) {
          throw std::invalid_argument{"DuplicateAgent"};
        }
      }
    }
  }

  inline void prepareStaging(std::size_t count) {
    while (staging_.size() > count) {
      staging_.pop_back();
    }

    staging_.reserve(count);
    while (staging_.size() < count) {
      staging_.emplace_back(memory_);
    }
  }

  inline static void assign(Agent<Memory> &agent, const AgentSnapshotEntry &entry) {
    agent.pane_id = entry.pane_id;
    agent.pane_generation = entry.pane_generation;
    agent.pane_index = entry.pane_index;
    agent.session_id = entry.session_id;
    agent.work_tree = entry.work_tree;
    agent.location = entry.location;
    agent.status = entry.status;
    agent.blocked_reason = entry.blocked_reason;
    agent.provider_kind = entry.provider;
    agent.attachments = entry.attachments;
    agent.title_state = entry.title_state;
    agent.title = entry.session_title;
    agent.provider_name = entry.provider_name;
    agent.workspace_label = entry.workspace_label;
    agent.display_name = entry.display_name;
    agent.icon = entry.icon;
    agent.detail = entry.last_event;
    agent.plan_step = entry.plan_step;
    agent.final_message = entry.final_message;
    agent.plan_done = entry.plan_done;
    agent.plan_total = entry.plan_total;
    agent.status_age_s = entry.status_age_s;
  }

  Memory &memory_;
  Vector<Agent<Memory>, Memory> entries_;
  Vector<Agent<Memory>, Memory> staging_;
  std::array<AgentStatusChange, capacity> status_changes_;
  std::size_t status_change_count_ = 0;
  std::uint64_t revision_ = 0;
  std::uint64_t now_ns_ = 0;
  bool retain_clocks_ = false;
};

}
}

// Interface: application/workspace_replica.cppm
export {
namespace telar::gui {

template <Allocator Memory>
class WorkspaceReplica {
public:
  static constexpr std::size_t maximum_workspaces = 64;
  static constexpr std::size_t maximum_worktrees = 64;
  static constexpr std::size_t average_path_bytes = 512;
  static constexpr std::size_t path_pool_bytes = maximum_workspaces * average_path_bytes;

  inline explicit WorkspaceReplica(Memory &memory)
      : memory_(memory),
        entries_(AllocatorRef<Workspace<Memory>, Memory>{memory}),
        staging_entries_(AllocatorRef<Workspace<Memory>, Memory>{memory}),
        worktrees_(AllocatorRef<Worktree<Memory>, Memory>{memory}),
        staging_worktrees_(AllocatorRef<Worktree<Memory>, Memory>{memory}) {}

  [[nodiscard]] inline const auto &entries() const noexcept {
    return entries_;
  }

  [[nodiscard]] inline auto projects() const noexcept {
    return std::span<const Workspace<Memory>>{entries_}.first(project_count_);
  }

  [[nodiscard]] inline const auto &worktrees() const noexcept {
    return worktrees_;
  }

  [[nodiscard]] inline auto begin() noexcept {
    return entries_.begin();
  }

  [[nodiscard]] inline auto end() noexcept {
    return entries_.end();
  }

  [[nodiscard]] inline auto begin() const noexcept {
    return entries_.begin();
  }

  [[nodiscard]] inline auto end() const noexcept {
    return entries_.end();
  }

  [[nodiscard]] inline std::uint64_t revision() const noexcept {
    return revision_;
  }

  [[nodiscard]] inline std::size_t dropped() const noexcept {
    return dropped_;
  }

  [[nodiscard]] inline const Worktree<Memory> *worktree(std::uint64_t identity) const noexcept {
    if (identity == 0) {
      return nullptr;
    }

    const auto row = std::ranges::find(worktrees_, identity, &Worktree<Memory>::id);

    return row == worktrees_.end() ? nullptr : &*row;
  }

  [[nodiscard]] inline const Worktree<Memory> *worktreeOfWorkspace(std::uint64_t identity) const noexcept {
    const auto row = std::ranges::find(worktrees_, std::optional{identity}, &Worktree<Memory>::workspace);

    return row == worktrees_.end() ? nullptr : &*row;
  }

  [[nodiscard]] inline std::size_t indexOf(std::uint64_t identity) const noexcept {
    const auto row = std::ranges::find_if(entries_, [identity](const auto &entry) {
      return entry.location.kind == WorkspaceLocation::Kind::workspace && entry.location.id == identity;
    });

    return row == entries_.end() ? entries_.size() : static_cast<std::size_t>(row - entries_.begin());
  }

  [[nodiscard]] inline std::uint64_t projectOf(std::uint64_t workspace) const noexcept {
    const auto *row = worktreeOfWorkspace(workspace);

    return row != nullptr && indexOf(row->source) < entries_.size() ? row->source : workspace;
  }

  inline void resetSource() noexcept {
    revision_ = 0;
  }

  inline bool apply(const WorkspaceList &snapshot) {
    if (snapshot.revision <= revision_) {
      return false;
    }

    validateCapacity(snapshot);
    for (const auto &row : snapshot.worktrees) {
      static_cast<void>(ValueCodec<WorktreeListEntry>::encodedSize(row));
    }

    std::array<const WorkspaceListEntry *, maximum_workspaces> ordered{};
    std::size_t count = 0;
    for (const auto &entry : snapshot.entries) {
      if (!holdsWorktree(snapshot, entry.workspace)) {
        ordered[count++] = &entry;
      }
    }

    const auto project_count = count;
    for (const auto &entry : snapshot.entries) {
      if (holdsWorktree(snapshot, entry.workspace)) {
        ordered[count++] = &entry;
      }
    }

    const auto retained = retainedCount(std::span{ordered}.first(count));
    prepare(staging_entries_, retained);
    prepare(staging_worktrees_, snapshot.worktrees.size());
    for (std::size_t index = 0; index < retained; ++index) {
      assign(staging_entries_[index], *ordered[index]);
    }

    for (std::size_t index = 0; index < snapshot.worktrees.size(); ++index) {
      assign(staging_worktrees_[index], snapshot.worktrees[index]);
    }

    entries_.swap(staging_entries_);
    worktrees_.swap(staging_worktrees_);
    project_count_ = std::min(project_count, retained);
    dropped_ = count - retained;
    revision_ = snapshot.revision;

    return true;
  }

private:
  inline static void validateCapacity(const WorkspaceList &snapshot) {
    if (snapshot.entries.size() > maximum_workspaces) {
      throw std::length_error{"TooManyWorkspaces"};
    }

    if (snapshot.worktrees.size() > maximum_worktrees) {
      throw std::length_error{"TooManyWorktrees"};
    }
  }

  inline static bool holdsWorktree(const WorkspaceList &snapshot, std::uint64_t identity) noexcept {
    return std::ranges::any_of(snapshot.worktrees, [identity](const auto &row) {
      return row.workspace == identity;
    });
  }

  inline static std::size_t retainedCount(std::span<const WorkspaceListEntry *const> ordered) {
    std::size_t path_bytes = 0;
    for (std::size_t index = 0; index < ordered.size(); ++index) {
      const auto &entry = *ordered[index];
      static_cast<void>(ValueCodec<WorkspaceListEntry>::encodedSize(entry));
      if (entry.path.size() > path_pool_bytes - path_bytes) {
        return index;
      }

      for (const auto *previous : ordered.first(index)) {
        if (previous->workspace == entry.workspace) {
          throw std::invalid_argument{"DuplicateWorkspace"};
        }
      }

      path_bytes += entry.path.size();
    }

    return ordered.size();
  }

  template <typename Row>
  inline void prepare(Vector<Row, Memory> &rows, std::size_t count) {
    while (rows.size() > count) {
      rows.pop_back();
    }

    rows.reserve(count);
    while (rows.size() < count) {
      rows.emplace_back(memory_);
    }
  }

  inline static void assign(Workspace<Memory> &row, const WorkspaceListEntry &entry) {
    row.location = {.kind = WorkspaceLocation::Kind::workspace, .id = entry.workspace};
    row.name = entry.name;
    row.path = entry.path;
    row.branch = entry.branch;
    row.tab_count = entry.tab_count;
    row.dirty = entry.dirty;
  }

  inline static void assign(Worktree<Memory> &row, const WorktreeListEntry &entry) {
    row.id = entry.worktree;
    row.source = entry.source;
    row.workspace = entry.workspace;
    row.created_by = entry.created_by;
    row.coordinator = entry.coordinator;
    row.state = entry.state;
    row.path = entry.path.substr(entry.path.size() - std::min(entry.path.size(), Worktree<Memory>::retained_path_bytes));
    row.branch = entry.branch;
    row.base = entry.base;
    row.title = entry.title;
    row.diff_added = entry.diff_added;
    row.diff_removed = entry.diff_removed;
    row.diff_files = entry.diff_files;
    row.commits_ahead = entry.commits_ahead;
    row.command_label = entry.command_label;
    row.command_state = entry.command_state;
    row.command_exit = entry.command_exit;
  }

  Memory &memory_;
  Vector<Workspace<Memory>, Memory> entries_;
  Vector<Workspace<Memory>, Memory> staging_entries_;
  Vector<Worktree<Memory>, Memory> worktrees_;
  Vector<Worktree<Memory>, Memory> staging_worktrees_;
  std::uint64_t revision_ = 0;
  std::size_t project_count_ = 0;
  std::size_t dropped_ = 0;
};

}
}
