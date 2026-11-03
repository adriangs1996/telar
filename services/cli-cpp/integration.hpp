#pragma once

#include "integration_options.hpp"
#include "telar_base/memory/allocator.hpp"

namespace telar::runtime::cli {

int runIntegration(BudgetAllocator<SystemAllocator> &memory, const IntegrationOptions &options);

}
