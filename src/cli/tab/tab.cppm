export module telar.cli.tab;

import std;

import telar.cli.window;

import telar.cli.worktree_git;
import telar.base.memory.allocators;

// Interface: config_check.cppm
export {
  namespace telar::runtime::cli {

    int checkConfiguration(const window::ConfigCheckOptions& options);

  }
}

// Interface: history_paths.cppm
export {
  namespace telar::runtime::cli {

    // Receives each workspace path the history recorded.
    class HistoryPathVisitor {
    public:
      virtual void operator()(std::string_view path) = 0;

    protected:
      ~HistoryPathVisitor() = default;
    };

    // Each workspace path the history at `database` recorded. A database that
    // exists but cannot be opened fails; a missing one records none.
    void historyPaths(const char* database, HistoryPathVisitor& visit);

  }
}

// Interface: tab.cppm
export {
  namespace telar::runtime::cli::sessions {

    int tab(Memory& memory, const TabOptions& options);

  }
}
