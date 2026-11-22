module telar.cli.commands.integration.settings;

import std;

import telar.platform.paths;
import telar.platform.process;
import telar.wire.vocabulary;

namespace telar::runtime::cli {

  int runIntegration(Memory& memory, const IntegrationOptions& options) {
    const ExecutablePath executable;
    const ProcessEnvironment environment;

    if (options.editor) {
      return integration::runEditor(options, executable.view());
    }

    if (options.neovim) {
      return integration::runNeovim(memory, options, environment);
    }

    if (options.provider == AgentProvider::pi || options.provider == AgentProvider::opencode) {
      return integration::runExtension(memory, options, environment, executable.view());
    }

    return integration::runSettings(memory, options, environment, executable.view());
  }

}
