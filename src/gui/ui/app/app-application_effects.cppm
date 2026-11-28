export module telar.gui.ui.app:application_effects;

import telar.gui.ui.app.overlays.notifications;
import telar.gui.foundation.system;
import telar.gui.application;
import telar.gui.foundation.core;
import telar.wire.vocabulary;

export namespace telar::gui::qt {

  class ApplicationController;

  // The desktop the window's clients reach through their MachineEffects: its notifications and
  // its one sound at a time.
  struct ApplicationEffects final : application::HostEffects {
    using Notifier = SystemNotifier<ApplicationNotificationHost, ApplicationAllocator>;
    using Player = SoundPlayer<ApplicationSoundHost, ApplicationController>;

    [[tbc::hot_path]] inline ApplicationEffects(Notifier& notifications, Player& sounds) noexcept
        : notifier(notifications),
          player(sounds) {}

    bool postNotification(const NotificationPayload& payload) override;
    bool playSound(AgentSound sound) override;

    Notifier& notifier;
    Player& player;
  };

}
