#include "idle_work.hpp"
#include <utility>

namespace workbench {
  IdleWork::IdleWork(std::function<bool()> step)
      : step_(std::move(step)) {
    timer_.setSingleShot(true);
    timer_.setInterval(0);
    QObject::connect(&timer_, &QTimer::timeout, &timer_, [this] {
      if (step_()) {
        timer_.start();
      }
    });
  }

  void IdleWork::wake() {
    if (!timer_.isActive()) {
      timer_.start();
    }
  }
} // namespace workbench
