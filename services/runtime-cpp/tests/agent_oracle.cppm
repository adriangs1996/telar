export module telar.runtime.tests.agent_oracle;

import std;
export import telar.runtime.tests.protocol_peer;

using namespace telar;

export {
void recordAgents(ProtocolPeer &peer, std::ostream &dump) {
  auto snapshot = peer.exchange<AgentSnapshot>(QueryAgents{999});
  std::vector<AgentSnapshotEntry> entries{snapshot.entries.begin(), snapshot.entries.end()};
  for (auto &entry : entries) {
    entry.pane_id = 1;
    entry.pane_generation = 1;
    entry.location = {.workspace = {.id = 1},
                      .tab_id = 1};
    entry.process_id = 1;
    entry.session_id = {};
    entry.status_age_s = 0;
    entry.sequence = 1;
    entry.observed_at_ms = 0;
    entry.expires_at_ms = 0;
  }
  snapshot.entries = entries;
  snapshot.revision = 1;
  peer.record(dump, snapshot);
}
}
