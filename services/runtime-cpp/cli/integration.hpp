#pragma once

#include "../memory/allocator.hpp"
#include "integration_options.hpp"

namespace telar::runtime::cli {

int runIntegration(BudgetAllocator<SystemAllocator> &memory, const IntegrationOptions &options);

}
