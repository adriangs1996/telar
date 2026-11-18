#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstdlib>
#include <cstring>
#include <unistd.h>

import std;
import telar.testing;
import telar.cli.tab;

namespace {

  using telar::testing::check;

  using namespace telar::runtime::cli;

  class Collected final : public HistoryPathVisitor {
  public:
    void operator()(std::string_view path) override {
      paths.emplace_back(path);
    }

    std::vector<std::string> paths;
  };

  class Directory {
  public:
    Directory() {
      std::strcpy(path_.data(), "/tmp/telar-history-paths.XXXXXX");
      check(::mkdtemp(path_.data()) != nullptr);
    }

    ~Directory() {
      std::error_code ignored;

      std::filesystem::remove_all(path_.data(), ignored);
    }

    std::string path(std::string_view name) const {
      return std::string{path_.data()} + "/" + std::string{name};
    }

  private:
    std::array<char, 64> path_{};
  };

  // What `historyPaths` makes of the file: the paths it visited, or the error it threw.
  std::string outcome(const std::string& database) {
    Collected collected;

    try {
      historyPaths(database.c_str(), collected);
    } catch (const std::runtime_error& error) {
      return error.what();
    }

    return std::format("{} paths", collected.paths.size());
  }

  // An install that never wrote history resolves repositories from open workspaces alone.
  void missingDatabase() {
    const Directory directory;

    check(outcome(directory.path("history.db")) == "0 paths");
  }

  // A runtime that is still creating its schema has recorded no paths yet.
  void schemaPending() {
    const Directory directory;
    const auto database = directory.path("history.db");

    std::ofstream{database};
    check(outcome(database) == "0 paths");
  }

  // A history that cannot be read is an error, not an empty history.
  void unreadableDatabase() {
    const Directory directory;
    const auto database = directory.path("history.db");

    std::ofstream{database} << "garbage that is not an SQLite database, long enough to fill its header";
    check(outcome(database) == "RepositoryHistoryUnavailable");
  }

  const telar::testing::Case case_missing_database{"history_paths.missing_database", missingDatabase};
  const telar::testing::Case case_schema_pending{"history_paths.schema_pending", schemaPending};
  const telar::testing::Case case_unreadable_database{"history_paths.unreadable_database", unreadableDatabase};

}
