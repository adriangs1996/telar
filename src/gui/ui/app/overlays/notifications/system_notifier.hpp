#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/memory.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_wire/serializers/telar_cells.hpp"
#include "telar_wire/serializers/telar_frame.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include "ui/kit/process/command_process.hpp"
#include "ui/kit/process/host_command.hpp"
#include <QProcess>
#include <algorithm>
#include <array>
#include <cassert>
#include <charconv>
#include <chrono>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <system_error>
#include <variant>

#pragma once

import telar.gui.application;
import telar.gui.foundation.system;
import telar.base.ds;

namespace telar::gui::qt {

  struct NativeNotificationHost {
    static constexpr auto timeout = std::chrono::seconds{3};

    static void start(QProcess& process, const NotificationPayload& payload) {
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

    explicit SystemNotifier(Memory& memory)
        : memory_(memory) {}

    [[nodiscard]] std::size_t activeCount() const noexcept {
      std::size_t count = 0;

      for (const auto& delivery : deliveries_) {
        if (delivery && (*delivery)->process.active()) {
          ++count;
        }
      }

      return count;
    }

    [[nodiscard]] bool post(const NotificationPayload& payload) {
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

      void commandFinished([[maybe_unused]] ds::Option<CommandFailure> failure) noexcept {
        assert(!process.active());
      }
    };

    Memory& memory_;
    ds::Array<ds::Option<ds::Box<Delivery, Memory>>, maximum_active> deliveries_;
  };

}
