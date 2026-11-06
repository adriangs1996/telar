#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cstdint>
#include <limits>
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <span>
#include <variant>
#include <cmath>
#include "telar_client/serializers/telar_messages.hpp"
#include <ranges>
#include "telar_client/serializers/telar_cells.hpp"
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "../qt/application.hpp"
#include "../qt/pointer_dispatcher.hpp"
#include <stdexcept>

#pragma once
#include "qt/application.hpp"
#include "qt/pointer_dispatcher.hpp"


import telar.gui.application.sound_playback;
import telar.gui.input.child_mouse;
import telar.gui.platform.profile_file;
import telar.gui.presentation.frame_pacer;

namespace telar::gui::test {

struct FramePacing {
  [[nodiscard]] static bool requestsPending(const qt::Application &application) noexcept {
    return application.session().requestsPending();
  }

  [[nodiscard]] static TabDropSurface tabs(const qt::Application &application) {
    return application.tabDropSurface();
  }

  static void presentTabs(qt::Application &application, const TabDropSurface &surface) {
    application.presented_tabs_ = surface;
    application.pointer_dispatcher_.presentTabs(surface);
  }

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
