#pragma once

#include "command_limit.hpp"
#include <climits>
#include <dlfcn.h>
#include <filesystem>
#include <stdexcept>
#include <string_view>
#include <utility>

// Older glibc keeps these in libdl. Keep the CLI linkable there; history
// discovery reports unavailability when no loader is present. A static
// release build links SQLite instead (TELAR_LINKED_SQLITE).
#if defined(__linux__) && !TELAR_LINKED_SQLITE
#pragma weak dlopen
#pragma weak dlsym
#pragma weak dlclose
#endif

// SQLite's handles stay opaque here; a linked build calls its functions
// through the same signatures the loader resolves.
struct HistoryDatabase;
struct HistoryStatement;

#if TELAR_LINKED_SQLITE
extern "C" {
int sqlite3_open_v2(const char *, HistoryDatabase **, int, const char *);
int sqlite3_close(HistoryDatabase *);
int sqlite3_prepare_v2(HistoryDatabase *, const char *, int, HistoryStatement **, const char **);
int sqlite3_finalize(HistoryStatement *);
int sqlite3_step(HistoryStatement *);
const unsigned char *sqlite3_column_text(HistoryStatement *, int);
int sqlite3_column_bytes(HistoryStatement *, int);
int sqlite3_busy_timeout(HistoryDatabase *, int);
}
#endif

namespace telar::runtime::cli {

// The workspace paths the history database recorded, read as Zig's
// `repository_discovery.find` does. Hooks must not load SQLite, so its public
// ABI is resolved only while a command searches history.
class HistoryPathReader {
public:
  static constexpr std::size_t maximum_paths = 4096;

  // Opens `path` read-only; false when SQLite cannot open it.
  bool open(const char *path) {
#if TELAR_LINKED_SQLITE
    open_ = &sqlite3_open_v2;
    close_ = &sqlite3_close;
    prepare_ = &sqlite3_prepare_v2;
    finalize_ = &sqlite3_finalize;
    step_ = &sqlite3_step;
    text_ = &sqlite3_column_text;
    length_ = &sqlite3_column_bytes;
    const Timeout timeout = &sqlite3_busy_timeout;
#else
#if defined(__linux__)
    if (!::dlopen || !::dlsym || !::dlclose) {
      return false;
    }

    library_ = ::dlopen("libsqlite3.so.0", RTLD_NOW | RTLD_LOCAL);
    if (!library_) {
      library_ = ::dlopen("libsqlite3.so", RTLD_NOW | RTLD_LOCAL);
    }
#else
    library_ = ::dlopen("/usr/lib/libsqlite3.dylib", RTLD_NOW | RTLD_LOCAL);
#endif
    if (!library_) {
      return false;
    }

    open_ = symbol<Open>("sqlite3_open_v2");
    close_ = symbol<Close>("sqlite3_close");
    prepare_ = symbol<Prepare>("sqlite3_prepare_v2");
    finalize_ = symbol<Finalize>("sqlite3_finalize");
    step_ = symbol<Step>("sqlite3_step");
    text_ = symbol<Text>("sqlite3_column_text");
    length_ = symbol<Length>("sqlite3_column_bytes");
    const auto timeout = symbol<Timeout>("sqlite3_busy_timeout");
#endif
    if (open_(path, &database_, read_only, nullptr) != Result::ok) {
      return false;
    }

    constexpr int busy_timeout_ms = 5000;
    timeout(database_, busy_timeout_ms);
    return true;
  }

  HistoryPathReader() = default;

  ~HistoryPathReader() {
    release();
  }

  HistoryPathReader(const HistoryPathReader &) = delete;
  HistoryPathReader &operator=(const HistoryPathReader &) = delete;

  // A new runtime can accept clients while its history worker still creates
  // the schema: no session table means no recorded paths.
  template <typename Consumer>
  void each(Consumer &&consume) {
    prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='session'");
    const auto schema = step_(statement_);
    if (schema == Result::done) {
      return;
    }

    if (schema != Result::row) {
      throw std::runtime_error{"RepositoryHistoryUnavailable"};
    }

    prepare("SELECT DISTINCT workspace_path FROM session LIMIT 4097");
    std::size_t count = 0;
    for (;;) {
      const auto result = step_(statement_);
      if (result == Result::done) {
        return;
      }

      if (result != Result::row) {
        throw std::runtime_error{"RepositoryHistoryUnavailable"};
      }

      if (++count > maximum_paths) {
        reportCommandLimit({.name = "repository.max_recorded_paths", .noun = "recorded paths", .value = maximum_paths, .requested = count});
        throw std::runtime_error{"RepositoryDiscoveryLimit"};
      }

      const auto bytes = text_(statement_, first_column);
      const auto length = length_(statement_, first_column);
      if (length < 0 || (!bytes && length != 0)) {
        throw std::runtime_error{"RepositoryHistoryUnavailable"};
      }

      const std::string_view path{bytes ? reinterpret_cast<const char *>(bytes) : "", static_cast<std::size_t>(length)};
      if (path.size() >= PATH_MAX || path.contains('\0')) {
        continue;
      }

      consume(path);
    }
  }

private:
  using Database = HistoryDatabase;
  using Statement = HistoryStatement;

  enum Result : int {
    ok = 0,
    row = 100,
    done = 101
  };

  enum OpenFlag : int {
    read_only = 1
  };

  static constexpr int first_column = 0;
  using Open = int (*)(const char *, Database **, int, const char *);
  using Close = int (*)(Database *);
  using Prepare = int (*)(Database *, const char *, int, Statement **, const char **);
  using Finalize = int (*)(Statement *);
  using Step = int (*)(Statement *);
  using Text = const unsigned char *(*)(Statement *, int);
  using Length = int (*)(Statement *, int);
  using Timeout = int (*)(Database *, int);

  template <typename Function>
  Function symbol(const char *name) {
    const auto address = ::dlsym(library_, name);
    if (!address) {
      throw std::runtime_error{"RepositoryHistoryUnavailable"};
    }

    return reinterpret_cast<Function>(address);
  }

  void prepare(const char *sql) {
    if (statement_) {
      finalize_(std::exchange(statement_, nullptr));
    }

    constexpr int null_terminated = -1;
    if (prepare_(database_, sql, null_terminated, &statement_, nullptr) != Result::ok) {
      throw std::runtime_error{"RepositoryHistoryUnavailable"};
    }
  }

  void release() noexcept {
    if (statement_) {
      finalize_(std::exchange(statement_, nullptr));
    }

    if (database_ && close_) {
      close_(std::exchange(database_, nullptr));
    }

    if (library_) {
#if !TELAR_LINKED_SQLITE
      ::dlclose(std::exchange(library_, nullptr));
#endif
    }
  }

  void *library_ = nullptr;
  Database *database_ = nullptr;
  Statement *statement_ = nullptr;
  Open open_{};
  Close close_{};
  Prepare prepare_{};
  Finalize finalize_{};
  Step step_{};
  Text text_{};
  Length length_{};
};

// Each workspace path the history at `database` recorded. A database that
// exists but cannot be opened fails, as in Zig; a missing one records none.
template <typename Consumer>
void historyPaths(const char *database, Consumer &&consume) {
  HistoryPathReader reader;
  if (reader.open(database)) {
    reader.each(std::forward<Consumer>(consume));
    return;
  }

  std::error_code error;
  const bool exists = std::filesystem::exists(database, error);
  if (exists || (error && error != std::errc::no_such_file_or_directory)) {
    throw std::runtime_error{"RepositoryHistoryUnavailable"};
  }
}

}
