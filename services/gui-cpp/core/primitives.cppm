module;
#include "../application/dependencies.hpp"
#include "terminal_size.hpp"
#include "../input/wheel_accumulator.hpp"

export module telar.gui.core.primitives;

// Owned textual headers stay in this global module fragment only; importers
// reach their names through these declarations instead of including them.
export namespace telar::gui {
using telar::gui::Allocator;
using telar::gui::AllocatorRef;
using telar::gui::ApplicationAllocator;
using telar::gui::BudgetAllocator;
using telar::gui::Owned;
using telar::gui::ScrollPhase;
using telar::gui::ScrollSample;
using telar::gui::String;
using telar::gui::SynchronizedAllocator;
using telar::gui::SystemAllocator;
using telar::gui::TerminalGrid;
using telar::gui::Vector;
using telar::gui::WheelAccumulator;
using telar::gui::default_terminal_size;
using telar::gui::makeOwned;
}

