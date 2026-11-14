module telar.runtime.platform.request_worker;

namespace telar::runtime {

  HistoryQueryOrder::HistoryQueryOrder(const QueryHistory& query, bool persistent_client) noexcept
      : replaceable(persistent_client && query.offset == 0 && query.snapshot_id == 0 && query.entry_id == 0),
        distinct(query.distinct) {}

  bool HistoryQueryOrder::supersededBy(const HistoryQueryOrder& newer) const noexcept {
    return replaceable && newer.replaceable && distinct == newer.distinct;
  }

}
