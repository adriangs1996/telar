module;
#include "telar_wire/protocol/runtime.hpp"

export module telar.wire.runtime;

// Runtime state and shutdown, request outcomes, system metrics, proxy status and
// limits.
//
// The owned textual header stays in this global module fragment only; importers reach
// its names through these declarations.
//
// The vocabulary declares `RequestRuntimeState` and `SystemMetrics`. This module carries their
// schemas and exports the names too, so the units that send or decode them import
// this module.

// The schemas are specializations of `MessageSchema` in the global fragment. A reduced BMI
// drops the fragment declarations a module never names, so naming the template here keeps
// them reachable from importers.
export namespace telar {
  using telar::MessageSchema;
}

export namespace telar {
  using telar::LimitList;
  using telar::ProxyStatus;
  using telar::QueryLimits;
  using telar::ReportLimit;
  using telar::RequestCompleted;
  using telar::RequestFailed;
  using telar::RequestRuntimeState;
  using telar::RuntimeStop;
  using telar::RuntimeStopping;
  using telar::SystemMetrics;
}
