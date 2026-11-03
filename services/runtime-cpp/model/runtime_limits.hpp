#pragma once

#include "telar_base/diagnostics/limit_ledger.hpp"

namespace telar::runtime {

struct RuntimeLimits {
  LimitLedger runtime;
  LimitLedger clients;
  std::uint64_t refused_reports = 0;
};

}
