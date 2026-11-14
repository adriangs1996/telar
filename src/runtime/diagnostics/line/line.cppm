module;
#include "diagnostics/line.hpp"

export module telar.runtime.diagnostics.line;

import telar.base.diagnostics;

// Owned textual headers stay in this global module fragment only; importers
// reach their names through these declarations instead of including them.
export namespace telar::runtime::diagnostics {
  using telar::runtime::diagnostics::accumulate;
  using telar::runtime::diagnostics::Line;
  using telar::runtime::diagnostics::Timing;
}

export namespace telar::runtime::diagnostics {
  using telar::TimedScope;
}
