#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application/dependencies.hpp"
#include "ui/app/overlays/notifications/sound_player.hpp"
#include "ui/app/overlays/notifications/system_notifier.hpp"

#pragma once

import telar.gui.foundation.system;
import telar.gui.application;

namespace telar::gui::qt {

  class ApplicationController;

  // The desktop the window's clients reach through their MachineEffects: its notifications and
  // its one sound at a time.
  struct ApplicationEffects final : application::HostEffects {
    using Notifier = SystemNotifier<ApplicationNotificationHost, ApplicationAllocator>;
    using Player = SoundPlayer<ApplicationSoundHost, ApplicationController>;

    ApplicationEffects(Notifier& notifications, Player& sounds) noexcept
        : notifier(notifications),
          player(sounds) {}

    bool postNotification(const NotificationPayload& payload) override;
    bool playSound(AgentSound sound) override;

    Notifier& notifier;
    Player& player;
  };

}
