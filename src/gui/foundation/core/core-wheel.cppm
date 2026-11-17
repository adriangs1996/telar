module;
#include "foundation/core/wheel_accumulator.hpp"

export module telar.gui.foundation.core:wheel;

// The header stays textual for the Objective-C++ and Qt sources and declares its names in this
// namespace, so a Qt source that includes it after importing the module names one entity;
// module units reach the names through these declarations instead of including it.
export namespace telar::gui::inline foundation::inline core {
  using telar::gui::ScrollPhase;
  using telar::gui::ScrollSample;
  using telar::gui::WheelAccumulator;
}
