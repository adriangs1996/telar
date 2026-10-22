#pragma once

#include <QTimer>
#include <functional>

namespace workbench {
  // Runs work one step per turn of the event loop, after the events already waiting, until a
  // step reports nothing is left. Input and painting run between steps, so each step must fit in
  // a frame.
  class IdleWork final {
  public:
    // `step` does one step and returns whether more remain.
    explicit IdleWork(std::function<bool()> step);
    // Runs steps again until none remain; new work calls this.
    void wake();

  private:
    QTimer timer_;
    std::function<bool()> step_;
  };
} // namespace workbench
