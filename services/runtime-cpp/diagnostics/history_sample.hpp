#pragma once

#include "../history/metrics.hpp"
#include "line.hpp"

namespace telar::runtime::diagnostics {

inline void writeHistorySample(Line &line, const HistoryMetrics &metrics) {
  line.field("history_available", metrics.available);
  line.field("history_sqlite_bytes", metrics.sqlite_bytes);
  line.field("sqlite_open_failures", !metrics.available);
  line.field("history_queue_depth", metrics.queue.depth);
  line.field("history_queue_high_water", metrics.queue.high_water);
  line.field("history_queue_dropped", metrics.queue.dropped);
  line.field("history_queries", metrics.query_submissions);
  line.field("history_query_failures", metrics.query_refusals);
  line.field("sqlite_writes", metrics.writes.timing.count);
  line.field("sqlite_write_failures", metrics.writes.failures);
  line.timing("sqlite_write_avg_us", "sqlite_write_max_us", metrics.writes.timing);
  line.field("sqlite_queries", metrics.queries.timing.count);
  line.field("sqlite_query_failures", metrics.queries.failures);
  line.timing("sqlite_query_avg_us", "sqlite_query_max_us", metrics.queries.timing);
}

}
