module telar.runtime.workers.request_worker;

import std;
import telar.base.text;

namespace telar::runtime {

  namespace {

    std::uint64_t scopeValue(const HistoryScopeValue& value) noexcept {
      if (const auto* path = std::get_if<std::string_view>(&value)) {
        return fnv1a64(*path);
      }

      if (const auto* pane = std::get_if<std::uint64_t>(&value)) {
        return *pane;
      }

      return 0;
    }

  }

  HistoryQueryOrder::HistoryQueryOrder(const QueryHistory& query, bool persistent_client) noexcept
      : replaceable(persistent_client && query.offset == 0 && query.snapshot_id == 0 && query.entry_id == 0),
        distinct(query.distinct),
        failed_only(query.failed_only),
        scope(query.scope),
        scope_value(scopeValue(query.scope_value)),
        author(query.author),
        match(query.match),
        limit(query.limit) {}

  bool HistoryQueryOrder::supersededBy(const HistoryQueryOrder& newer) const noexcept {
    const auto kind = [](const HistoryQueryOrder& order) {
      return std::tuple{order.distinct, order.failed_only, order.scope, order.scope_value, order.author, order.match, order.limit};
    };

    return replaceable && newer.replaceable && kind(*this) == kind(newer);
  }

}
