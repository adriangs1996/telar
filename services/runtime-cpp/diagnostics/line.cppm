module;
#include "line.hpp"

export module telar.runtime.diagnostics.line;

// Owned textual headers stay in this global module fragment only; importers
// reach their names through these declarations instead of including them.
export namespace telar::runtime::diagnostics {
using telar::runtime::diagnostics::Line;
using telar::runtime::diagnostics::TimedScope;
using telar::runtime::diagnostics::Timing;
using telar::runtime::diagnostics::accumulate;
}

