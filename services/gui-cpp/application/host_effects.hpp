#pragma once

#include "notification_payload.hpp"
#include "presentation/frame_pacer.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <concepts>
#include <cstddef>
#include <cstdint>

namespace telar::gui {

struct HostEffectLimits {
  static constexpr std::size_t maximum_system_notifications = 240;
};

template <typename Host>
concept HostEffects = requires(Host &host, const NotificationPayload &payload, AgentSound sound) {
  { host.postNotification(payload) } -> std::same_as<bool>;
  { host.playSound(sound) } -> std::same_as<bool>;
};

template <typename Host>
concept PaneInputObserver = requires(Host &host, FramePacer::Pane pane, std::uint64_t now_ns) {
  { host.notePaneInput(pane, now_ns) } noexcept -> std::same_as<void>;
};

struct DiscardHostEffects {
  static bool postNotification([[maybe_unused]] const NotificationPayload &payload) noexcept {
    return false;
  }

  static bool playSound([[maybe_unused]] AgentSound sound) noexcept {
    return false;
  }
};

}
