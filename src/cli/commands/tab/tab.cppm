export module telar.cli.commands.tab;

import std;

import telar.cli.commands.window;

import telar.cli.commands.worktree_git;
import telar.base.memory.allocators;

// Interface: config_check.cppm
export {
  namespace telar::runtime::cli {

    int checkConfiguration(const window::ConfigCheckOptions& options);

  }
}

// Interface: tab.cppm
export {
  namespace telar::runtime::cli::sessions {

    int tab(Memory& memory, const TabOptions& options);

  }
}
