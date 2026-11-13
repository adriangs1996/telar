#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <array>
#include <charconv>
#include <concepts>
#include <cstddef>
#include <cstring>
#include <stdexcept>
#include <string_view>
#include <system_error>
#include <algorithm>
#include <cstdint>
#include <limits>
#include "telar_client/serializers/telar_protocol.hpp"
#include <optional>
#include <span>
#include <variant>
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "../core/memory.hpp"
#include "command_process.hpp"
#include "host_command.hpp"
#include <QProcess>
#include <cassert>

#pragma once
#include "core/memory.hpp"


import telar.gui.application.host_effects;
import telar.gui.platform.notification_commands;

namespace telar::gui::qt {

struct NativeNotificationHost {
  static constexpr auto timeout = std::chrono::seconds{3};

  static void start(QProcess &process, const NotificationPayload &payload) {
#ifdef __APPLE__
    platform::NativeNotificationCommand command;
    startHostCommand(process, command.prepare(payload));
#else
    startHostCommand(process, platform::NativeNotificationCommand::prepare(payload));
#endif
  }
};

#ifndef TELAR_GUI_NOTIFICATION_HOST
#define TELAR_GUI_NOTIFICATION_HOST ::telar::gui::qt::NativeNotificationHost
#endif

using ApplicationNotificationHost = TELAR_GUI_NOTIFICATION_HOST;

template <typename Host, Allocator Memory, std::size_t Capacity = HostEffectLimits::maximum_system_notifications>
  requires CommandHost<Host, NotificationPayload>
class SystemNotifier {
  static_assert(Capacity > 0);

public:
  static constexpr std::size_t maximum_active = Capacity;

  explicit SystemNotifier(Memory &memory)
      : memory_(memory) {}

  [[nodiscard]] std::size_t activeCount() const noexcept {
    std::size_t count = 0;
    for (const auto &delivery : deliveries_) {
      if (delivery && (*delivery)->process.active()) {
        ++count;
      }
    }

    return count;
  }

  [[nodiscard]] bool post(const NotificationPayload &payload) {
    for (auto &delivery : deliveries_) {
      if (!delivery) {
        delivery = makeOwned<Delivery>(memory_);
      }

      auto &process = (*delivery)->process;
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

    void commandFinished([[maybe_unused]] std::optional<CommandFailure> failure) noexcept {
      assert(!process.active());
    }
  };

  Memory &memory_;
  std::array<std::optional<Owned<Delivery, Memory>>, maximum_active> deliveries_;
};

}
