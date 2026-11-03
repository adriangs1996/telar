#include "integration.hpp"
#include "integration/extension.hpp"
#include "integration/settings.hpp"
#include "telar_platform/executable_path.hpp"

namespace telar::runtime::cli {

int runIntegration(BudgetAllocator<SystemAllocator> &memory, const IntegrationOptions &options) {
  const ExecutablePath executable;
  const ProcessEnvironment environment;
  if (options.provider == AgentProvider::pi || options.provider == AgentProvider::opencode) {
    return integration::runExtension(memory, options, environment, executable.view());
  }

  return integration::runSettings(memory, options, environment, executable.view());
}

}
