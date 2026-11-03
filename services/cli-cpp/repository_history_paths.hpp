#pragma once

#include "command_limit.hpp"
#include <dlfcn.h>
#include <filesystem>

namespace telar::runtime::cli::repository {

// Only repository discovery loads SQLite. Hooks do not load it at startup.
class HistoryPaths {
  struct Connection;
  struct Statement;

  enum SQLiteCode {
    ok = 0,
    row = 100,
    done = 101
  };

  enum OpenMode {
    read_only = 1
  };

public:
  explicit HistoryPaths(const std::string &path) {
    if (!std::filesystem::exists(path)) {
      return;
    }

#ifdef __APPLE__
    library_ = ::dlopen("/usr/lib/libsqlite3.dylib", RTLD_NOW | RTLD_LOCAL);
#else
    library_ = ::dlopen("libsqlite3.so.0", RTLD_NOW | RTLD_LOCAL);
#endif
    if (library_ == nullptr) {
      throw std::runtime_error{"RepositoryHistoryUnavailable"};
    }

    try {
      open_ = symbol<decltype(open_)>("sqlite3_open_v2");
      close_ = symbol<decltype(close_)>("sqlite3_close");
      prepare_ = symbol<decltype(prepare_)>("sqlite3_prepare_v2");
      step_ = symbol<decltype(step_)>("sqlite3_step");
      finalize_ = symbol<decltype(finalize_)>("sqlite3_finalize");
      column_text_ = symbol<decltype(column_text_)>("sqlite3_column_text");
      column_bytes_ = symbol<decltype(column_bytes_)>("sqlite3_column_bytes");
      const auto busy = symbol<int (*)(Connection *, int)>("sqlite3_busy_timeout");
      if (open_(path.c_str(), &database_, read_only, nullptr) != ok) {
        throw std::runtime_error{"RepositoryHistoryUnavailable"};
      }

      constexpr int busy_timeout_ms = 5000;
      busy(database_, busy_timeout_ms);
    } catch (...) {
      cleanup();
      throw;
    }
  }

  ~HistoryPaths() {
    cleanup();
  }

  HistoryPaths(const HistoryPaths &) = delete;
  HistoryPaths &operator=(const HistoryPaths &) = delete;

  std::vector<std::string> read() {
    std::vector<std::string> paths;
    if (database_ == nullptr) {
      return paths;
    }

    auto schema = rows("SELECT name FROM sqlite_master WHERE type='table' AND name='session'");
    if (schema.empty()) {
      return paths;
    }

    paths = rows("SELECT DISTINCT workspace_path FROM session LIMIT 4097");
    constexpr std::size_t max_recorded_paths = 4096;
    if (paths.size() > max_recorded_paths) {
      reportCommandLimit({.name = "repository.max_recorded_paths", .noun = "recorded paths", .value = max_recorded_paths, .requested = paths.size()});
      throw std::runtime_error{"RepositoryDiscoveryLimit"};
    }

    return paths;
  }

private:
  template <typename Function>
  Function symbol(const char *name) {
    auto result = reinterpret_cast<Function>(::dlsym(library_, name));
    if (result == nullptr) {
      throw std::runtime_error{"RepositoryHistoryUnavailable"};
    }

    return result;
  }

  std::vector<std::string> rows(const char *sql) {
    Statement *statement = nullptr;
    if (prepare_(database_, sql, -1, &statement, nullptr) != ok) {
      throw std::runtime_error{"RepositoryHistoryUnavailable"};
    }

    try {
      std::vector<std::string> result;
      for (;;) {
        const auto status = step_(statement);
        if (status == done) {
          finalize_(statement);
          return result;
        }

        if (status != row) {
          throw std::runtime_error{"RepositoryHistoryUnavailable"};
        }

        const auto *text = column_text_(statement, 0);
        const auto length = column_bytes_(statement, 0);
        constexpr int max_path_bytes = 4096;
        if (length < 0 || length > max_path_bytes) {
          throw std::runtime_error{"RepositoryHistoryUnavailable"};
        }

        result.emplace_back(text == nullptr ? "" : reinterpret_cast<const char *>(text), static_cast<std::size_t>(length));
      }
    } catch (...) {
      finalize_(statement);
      throw;
    }
  }

  void cleanup() noexcept {
    if (database_ != nullptr && close_ != nullptr) {
      close_(database_);
    }

    if (library_ != nullptr) {
      ::dlclose(library_);
    }
  }

  void *library_ = nullptr;
  Connection *database_ = nullptr;
  int (*open_)(const char *, Connection **, int, const char *) = nullptr;
  int (*close_)(Connection *) = nullptr;
  int (*prepare_)(Connection *, const char *, int, Statement **, const char **) = nullptr;
  int (*step_)(Statement *) = nullptr;
  int (*finalize_)(Statement *) = nullptr;
  const unsigned char *(*column_text_)(Statement *, int) = nullptr;
  int (*column_bytes_)(Statement *, int) = nullptr;
};

}
