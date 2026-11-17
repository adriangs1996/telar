#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/memory/fixed_text.hpp"
#include "telar_wire/serializers/telar_cells.hpp"
#include "telar_wire/serializers/telar_frame.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include "ui/app/application_controller.hpp"
#include <QCoreApplication>
#include <QEvent>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <ranges>
#include <span>
#include <stdexcept>
#include <string_view>
#include <variant>

#pragma once
#include "ui/app/application_controller.hpp"

import telar.gui.layout.geometry;
import telar.gui.platform.awake_clock;
import telar.gui.presentation.frame_pacer;

namespace telar::gui::test {

  struct FramePacing {
    [[nodiscard]] static bool requestsPending(const qt::ApplicationController& application) noexcept {
      return application.session().requestsPending();
    }

    static void anchor(qt::ApplicationController& application, std::uint64_t now_ns) {
      if (!application.frames_.frame_pacer_) {
        throw std::logic_error{"The application has no window frame pacer"};
      }

      std::array<FramePacer::Pane, PaneLayout::maximum_panes> panes;
      const auto count = application.frames_.collectPacingPanes(panes);

      application.frames_.frame_pacer_->record(std::span{panes}.first(count), now_ns);
    }

    [[nodiscard]] static bool pending(const qt::ApplicationController& application) noexcept {
      return application.frames_.frame_pacer_ && application.frames_.frame_pacer_->pending();
    }

    // Presents the frames the window swapped: their presentation waits in the presenter's queue.
    static void presentSwapped(qt::ApplicationController& application) {
      QCoreApplication::sendPostedEvents(&application.frames_, QEvent::MetaCall);
    }

    static void release(qt::ApplicationController& application) {
      anchor(application, platform::AwakeClock::nowNanoseconds() - FramePacer::maximum_interval_ns);
      application.frames_.reconsider();
    }
  };

}
