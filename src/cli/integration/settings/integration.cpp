module telar.cli.integration.settings;

import std;

import telar.platform.paths;
import telar.platform.process;
import telar.base.diagnostics;
import telar.wire.vocabulary;
import telar.platform.primitives;

namespace telar::runtime::cli {

  int runIntegration(Memory& memory, const IntegrationOptions& options) {
    const ExecutablePath executable;
    const ProcessEnvironment environment;

    if (options.provider == AgentProvider::pi || options.provider == AgentProvider::opencode) {
      return integration::runExtension(memory, options, environment, executable.view());
    }

    return integration::runSettings(memory, options, environment, executable.view());
  }

}
