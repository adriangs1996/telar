#pragma once

#include "telar_client/serializers/telar_protocol.hpp"

namespace telar::runtime {

struct HistoryQueryOrder {
  explicit HistoryQueryOrder(const QueryHistory &query, bool persistent_client) noexcept
      : replaceable(persistent_client && query.offset == 0 && query.snapshot_id == 0 && query.entry_id == 0), distinct(query.distinct) {}

  bool supersededBy(const HistoryQueryOrder &newer) const noexcept {
    return replaceable && newer.replaceable && distinct == newer.distinct;
  }

  bool replaceable;
  bool distinct;
};

}
