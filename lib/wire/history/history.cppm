module;
#include "telar_client/protocol/history.hpp"

export module telar.wire.history;

// Command history: queries, imports, deletion, pruning and statistics.
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
  using telar::DeleteHistory;
  using telar::HistoryOutput;
  using telar::HistoryPruned;
  using telar::HistoryResults;
  using telar::HistoryStatsQuery;
  using telar::HistoryStatsResult;
  using telar::ImportHistory;
  using telar::PruneHistory;
  using telar::QueryHistory;
  using telar::ReadHistoryOutput;
}
