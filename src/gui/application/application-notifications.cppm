// The notices as ui drives them: the center the window paints, publishing, dismissing and
// choosing a notice, the limits ui reached and the agent sound that ended.
export module telar.gui.application:notifications;

import std;

import :session;
import telar.base.diagnostics;
import telar.gui.features.notifications;
import telar.wire.vocabulary;

export namespace telar::gui::application::notifications {

  using features::notifications::NotificationActionLabel;
  using features::notifications::NotificationCardGeometry;
  using features::notifications::NotificationCenter;
  using features::notifications::NotificationHeight;
  using features::notifications::NotificationHidden;
  using features::notifications::NotificationId;
  using features::notifications::NotificationInput;
  using features::notifications::NotificationItem;
  using features::notifications::NotificationMetrics;
  using features::notifications::NotificationPlacement;
  using features::notifications::NotificationStack;
  using features::notifications::NotificationStackRequest;
  using features::notifications::NotificationText;

  // The notices the window paints, valid until a use case changes them.
  [[nodiscard]] const NotificationCenter& center(const Session& session) noexcept;

  // Changes whenever the notices do.
  [[nodiscard]] std::uint64_t revision(const Session& session) noexcept;

  // Shows `input` now, and posts it to the desktop when the configuration delivers there.
  void publish(Session& session, NotificationInput input);

  // Moves the notices' fades and expiries to `now_ns`; true when any changed.
  bool advance(Session& session, std::uint64_t now_ns) noexcept;

  bool dismiss(Session& session, NotificationId id) noexcept;

  // Fades notice `id` out and shows the pane, tab or workspace it points at.
  bool activate(Session& session, NotificationId id);

  // Whether the pane `target` names is on screen, where a notice about it would only repeat it.
  [[nodiscard]] bool targetVisible(const Session& session, NotificationTarget target) noexcept;

  // Counts a reach of a limit, reports it to the runtime when due and shows it when due.
  void reportLimit(Session& session, LimitReach reach);

  // The agent sound playing ended: the queued one, if any, starts.
  void completeSound(Session& session);

}

// What the session's routing and the other use cases hand the notices; ui never calls these.
namespace telar::gui::application::notifications {

  void publish(Session& session, NotificationInput input, std::uint64_t now_ns);

  // Counts a reach of a limit and reports it to the runtime when due; the caller shows it.
  features::notifications::LimitRecorded countLimitReach(Session& session, LimitReach reach);

  // What the notice of the limit in `slot` says.
  [[nodiscard]] features::notifications::LimitNotices::Description describeLimit(const Session& session, features::notifications::LimitSlot slot);

  Change receive(Session& session, const Notification& message);

  Change receive(Session& session, const AgentSoundNotification& message);

}
