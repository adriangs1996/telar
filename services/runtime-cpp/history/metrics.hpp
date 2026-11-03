#pragma once

#include "../diagnostics/operation.hpp"
#include "../diagnostics/request_queue.hpp"
#include "telar_base/diagnostics/config.hpp"
#include "telar_client/serializers/telar_protocol.hpp"

namespace telar::runtime {

struct HistoryMetrics {
  bool available = false;
  diagnostics::OperationSnapshot writes{};
  diagnostics::OperationSnapshot queries{};
  diagnostics::RequestQueueSnapshot queue{};
  std::uint64_t query_submissions = 0;
  std::uint64_t query_refusals = 0;
  std::uint64_t sqlite_bytes = 0;
};

struct HistoryCounters {
#if TELAR_DIAGNOSTICS
  diagnostics::OperationCounters writes;
  diagnostics::OperationCounters queries;

  template <typename Message>
  diagnostics::OperationCounters *operation() noexcept {
    if constexpr (std::same_as<Message, QueryHistory>) {
      return &queries;
    } else if constexpr (std::same_as<Message, ImportHistory> || std::same_as<Message, ReportAgentCommand>) {
      return &writes;
    } else {
      return nullptr;
    }
  }

  HistoryMetrics snapshot(bool available) const noexcept {
    return {.available = available, .writes = writes.snapshot(), .queries = queries.snapshot()};
  }
#endif
};

}
