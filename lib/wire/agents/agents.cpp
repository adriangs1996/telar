module telar.wire.agents;

import std;
import telar.wire.vocabulary;

// The owned header declares these in the global module, so their definitions belong to it too.
extern "C++" {
namespace telar {

  void ReportAgentSession::validate() const {
    validateAgentSession(session, false);
  }

  void ReportAgent::validate() const {
    validateAgentSession(session, true);
    if (state != AgentReportState::blocked && blocked_reason != AgentBlockedReason::none) {
      throw EncodingError{"Unexpected blocked reason"};
    }
  }

  void ReportAgentCommand::validate() const {
    validateAgentSession(session, true);
    if (phase == AgentCommandPhase::started && exit_code) {
      throw EncodingError{"Unexpected command exit code"};
    }
  }

  void ReportAgentProgress::validate() const {
    if (plan_done > plan_total) {
      throw EncodingError{"Invalid agent plan counts"};
    }
  }

}
}
