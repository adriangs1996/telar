module;
#include "telar_client/protocol/agents.hpp"

export module telar.wire.agents;

// Agent reports and snapshots, and the requests that act on agents.
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
  using telar::AcknowledgeAgent;
  using telar::AgentSnapshot;
  using telar::AgentSoundNotification;
  using telar::InterruptAgent;
  using telar::QueryAgents;
  using telar::ReportAgent;
  using telar::ReportAgentCommand;
  using telar::ReportAgentProgress;
  using telar::ReportAgentSession;
  using telar::ReportAgentTitle;
}
