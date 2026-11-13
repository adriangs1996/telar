#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "../qt/application.hpp"
#include "../qt/pointer_dispatcher.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
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
#include "qt/application.hpp"
#include "qt/pointer_dispatcher.hpp"

import telar.gui.layout.geometry;
import telar.gui.input.child_mouse;
import telar.gui.platform.profile_file;
import telar.gui.presentation.frame_pacer;

namespace telar::gui::test {

  struct FramePacing {
    [[nodiscard]] static bool requestsPending(const qt::Application& application) noexcept {
      return application.session().requestsPending();
    }

    [[nodiscard]] static TabDropSurface tabs(const qt::Application& application) {
      return application.tabDropSurface();
    }

    static void presentTabs(qt::Application& application, const TabDropSurface& surface) {
      application.presented_tabs_ = surface;
      application.pointer_dispatcher_.presentTabs(surface);
    }

    static void anchor(qt::Application& application, std::uint64_t now_ns) {
      if (!application.frame_pacer_) {
        throw std::logic_error{"The application has no window frame pacer"};
      }

      std::array<FramePacer::Pane, PaneLayout::maximum_panes> panes;
      const auto count = application.collectPacingPanes(panes);

      application.frame_pacer_->record(std::span{panes}.first(count), now_ns);
    }

    [[nodiscard]] static bool pending(const qt::Application& application) noexcept {
      return application.frame_pacer_ && application.frame_pacer_->pending();
    }

    static void release(qt::Application& application) {
      anchor(application, platform::AwakeClock::nowNanoseconds() - FramePacer::maximum_interval_ns);
      application.reconsiderFrame();
    }
  };

}
