module;
#include "telar_client/protocol/execution.hpp"

export module telar.wire.execution;

// Commands the runtime executes for a client, and their output.
//
// The owned textual header stays in this global module fragment only; importers reach
// its names through these declarations.

// The schemas are specializations of `MessageSchema` in the global fragment. A reduced BMI
// drops the fragment declarations a module never names, so naming the template here keeps
// them reachable from importers.
export namespace telar {
  using telar::MessageSchema;
}

export namespace telar {
  using telar::ExecutionReply;
  using telar::ExecutionRequest;
}
