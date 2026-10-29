#pragma once

#include "application/pane_layout.hpp"
#include "platform/awake_clock.hpp"
#include "presentation/frame_pacer.hpp"
#include "qt/application.hpp"
#include <array>
#include <cstdint>
#include <span>
#include <stdexcept>

namespace telar::gui::test {

struct FramePacing {
  static void anchor(qt::Application &application, std::uint64_t now_ns) {
    if (!application.frame_pacer_) {
      throw std::logic_error{"The application has no window frame pacer"};
    }

    std::array<FramePacer::Pane, PaneLayout::maximum_panes> panes;
    const auto count = application.collectPacingPanes(panes);
    application.frame_pacer_->record(std::span{panes}.first(count), now_ns);
  }

  [[nodiscard]] static bool pending(const qt::Application &application) noexcept {
    return application.frame_pacer_ && application.frame_pacer_->pending();
  }

  static void release(qt::Application &application) {
    anchor(application, platform::AwakeClock::nowNanoseconds() - FramePacer::maximum_interval_ns);
    application.reconsiderFrame();
  }
};

}
