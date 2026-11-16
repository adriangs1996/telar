#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application_controller.hpp"
#include "ui/foundation/timing/deadline_timer.hpp"
#include <QTimer>
#include <exception>
#include <optional>

import telar.gui.platform.awake_clock;

namespace telar::gui::qt {

  void ApplicationController::initializeGraphicsRecovery() {
    graphics_resume_timer_.setSingleShot(true);
    graphics_resume_timer_.setTimerType(Qt::PreciseTimer);
    connect(&graphics_resume_timer_, &QTimer::timeout, this, [this] {
      try {
        session().resumeGraphics();
      } catch (const std::exception& error) {
        fail(error);
      }

      refreshPanes();
      scheduleGraphicsRecovery();
    });
  }

  void ApplicationController::scheduleGraphicsRecovery() {
    scheduleDeadline(graphics_resume_timer_, session().ready() ? session().graphicsResumeDeadline() : std::nullopt, platform::AwakeClock::nowNanoseconds());
  }

}
