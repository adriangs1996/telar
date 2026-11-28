export module telar.gui.ui.app.overlays.notifications:system_notifier;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.process;
import telar.gui.application;
import telar.gui.foundation.system;
import telar.base.ds;
import telar.gui.foundation.core;
import telar.wire.vocabulary;

export namespace telar::gui::qt {

  struct NativeNotificationHost {
    static constexpr auto timeout = std::chrono::seconds{3};

    [[tbc::hot_path]] inline static void start(QProcess& process, const NotificationPayload& payload) {
#ifdef __APPLE__
      system::NativeNotificationCommand command;

      startHostCommand(process, command.prepare(payload));
#else
      startHostCommand(process, system::NativeNotificationCommand::prepare(payload));
#endif
    }
  };

#ifndef TELAR_GUI_NOTIFICATION_HOST
#define TELAR_GUI_NOTIFICATION_HOST ::telar::gui::qt::NativeNotificationHost
#endif

  using ApplicationNotificationHost = TELAR_GUI_NOTIFICATION_HOST;

  template <typename Host, Allocator Memory, std::size_t Capacity = application::HostEffectLimits::maximum_system_notifications>
    requires CommandHost<Host, NotificationPayload>
  class SystemNotifier {
    static_assert(Capacity > 0);

  public:
    static constexpr std::size_t maximum_active = Capacity;

    [[tbc::generic]] explicit SystemNotifier(Memory& memory)
        : memory_(memory) {}

    [[tbc::generic]] [[nodiscard]] std::size_t activeCount() const noexcept {
      std::size_t count = 0;

      for (const auto& delivery : deliveries_) {
        if (delivery && (*delivery)->process.active()) {
          ++count;
        }
      }

      return count;
    }

    [[tbc::generic]] [[nodiscard]] bool post(const NotificationPayload& payload) {
      for (auto& delivery : deliveries_.viewMut()) {
        if (!delivery) {
          delivery = ds::makeBox<Delivery>(memory_);
        }

        auto& process = delivery.getMut().getMut().process;
        if (!process.active()) {
          process.start(payload);

          return true;
        }
      }

      return false;
    }

  private:
    struct Delivery {
      CommandProcess<Host, NotificationPayload, Delivery> process{*this};

      [[tbc::hot_path]] inline void commandFinished([[maybe_unused]] ds::Option<CommandFailure> failure) noexcept {
        if (process.active()) {
          std::terminate();
        }
      }
    };

    Memory& memory_;
    ds::Array<ds::Option<ds::Box<Delivery, Memory>>, maximum_active> deliveries_;
  };

}
