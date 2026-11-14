module;
#include "input/wheel_accumulator.hpp"

export module telar.gui.input.wheel_accumulator;

// The header stays textual for the Objective-C++ and Qt sources; module units reach its
// names through these declarations instead of including it.
export namespace telar::gui {
  using telar::gui::ScrollPhase;
  using telar::gui::ScrollSample;
  using telar::gui::WheelAccumulator;
}
