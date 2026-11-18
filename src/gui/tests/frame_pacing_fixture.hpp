#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/app/application_controller.hpp"
#include <QCoreApplication>
#include <QEvent>
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <stdexcept>

#pragma once

import telar.gui.foundation.model;
import telar.gui.foundation.system;
import telar.gui.features.window;

namespace telar::gui::test {

  struct FramePacing {
    [[nodiscard]] static bool requestsPending(const qt::ApplicationController& application) noexcept {
      return application.session().requestsPending();
    }

    static void anchor(qt::ApplicationController& application, std::uint64_t now_ns) {
      if (!application.frames_.frame_pacer_) {
        throw std::logic_error{"The application has no window frame pacer"};
      }

      std::array<features::window::FramePacer::Pane, PaneLayout::maximum_panes> panes;
      const auto count = application.frames_.collectPacingPanes(panes);

      application.frames_.frame_pacer_.getMut().record(std::span{panes}.first(count), now_ns);
    }

    [[nodiscard]] static bool pending(const qt::ApplicationController& application) noexcept {
      return application.frames_.frame_pacer_ && application.frames_.frame_pacer_->pending();
    }

    // Presents the frames the window swapped: their presentation waits in the presenter's queue.
    static void presentSwapped(qt::ApplicationController& application) {
      QCoreApplication::sendPostedEvents(&application.frames_, QEvent::MetaCall);
    }

    static void release(qt::ApplicationController& application) {
      anchor(application, system::AwakeClock::nowNanoseconds() - features::window::FramePacer::maximum_interval_ns);
      application.frames_.reconsider();
    }
  };

}
