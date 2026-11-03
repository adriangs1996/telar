#pragma once

#include "session_channel.hpp"
#include <dlfcn.h>

// Older glibc keeps these in libdl. Keep the standalone CLI linkable there;
// history discovery reports unavailability if no loader is present.
#if defined(__linux__)
#pragma weak dlopen
#pragma weak dlsym
#pragma weak dlclose
#endif

namespace telar::runtime::cli::sessions {

// The runtime already requires SQLite, but hooks must not load it. Resolve its
// public ABI only while searching history, keeping the CLI's startup unchanged.
class HistoryPathReader {
public:
  explicit HistoryPathReader(const char *path) {
    try {
#if defined(__linux__)
      if (!::dlopen || !::dlsym || !::dlclose) {
        throw Failure{"RepositoryHistoryUnavailable"};
      }
      library_ = ::dlopen("libsqlite3.so.0", RTLD_NOW | RTLD_LOCAL);
      if (!library_) {
        library_ = ::dlopen("libsqlite3.so", RTLD_NOW | RTLD_LOCAL);
      }
#else
      library_ = ::dlopen("/usr/lib/libsqlite3.dylib", RTLD_NOW | RTLD_LOCAL);
#endif
      if (!library_) {
        throw Failure{"RepositoryHistoryUnavailable"};
      }
      open_ = symbol<Open>("sqlite3_open_v2");
      close_ = symbol<Close>("sqlite3_close");
      prepare_ = symbol<Prepare>("sqlite3_prepare_v2");
      finalize_ = symbol<Finalize>("sqlite3_finalize");
      step_ = symbol<Step>("sqlite3_step");
      text_ = symbol<Text>("sqlite3_column_text");
      length_ = symbol<Length>("sqlite3_column_bytes");
      const auto timeout = symbol<Timeout>("sqlite3_busy_timeout");
      if (open_(path, &database_, read_only, nullptr) != Result::ok) {
        throw Failure{"RepositoryHistoryUnavailable"};
      }
      constexpr int busy_timeout_ms = 5000;
      timeout(database_, busy_timeout_ms);
    } catch (...) {
      release();
      throw;
    }
  }

  ~HistoryPathReader() {
    release();
  }

  HistoryPathReader(const HistoryPathReader &) = delete;
  HistoryPathReader &operator=(const HistoryPathReader &) = delete;

  template <typename Consumer>
  void each(Consumer &&consume) {
    prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='session'");
    const auto schema = step_(statement_);
    if (schema == Result::done) {
      return;
    }
    if (schema != Result::row) {
      throw Failure{"RepositoryHistoryUnavailable"};
    }
    prepare("SELECT DISTINCT workspace_path FROM session LIMIT 4097");
    std::size_t count = 0;
    for (;;) {
      const auto result = step_(statement_);
      if (result == Result::done) {
        return;
      }
      if (result != Result::row) {
        throw Failure{"RepositoryHistoryUnavailable"};
      }
      if (++count > maximum_paths) {
        throw Failure{"RepositoryDiscoveryLimit"};
      }
      const auto bytes = text_(statement_, first_column);
      const auto length = length_(statement_, first_column);
      if (length < 0 || (!bytes && length != 0)) {
        throw Failure{"RepositoryHistoryUnavailable"};
      }
      const std::string_view path{bytes ? reinterpret_cast<const char *>(bytes) : "", static_cast<std::size_t>(length)};
      if (path.size() >= PATH_MAX || path.contains('\0')) {
        continue;
      }
      consume(path);
    }
  }

private:
  struct Database;
  struct Statement;

  enum Result : int {
    ok = 0,
    row = 100,
    done = 101
  };

  enum OpenFlag : int {
    read_only = 1
  };

  static constexpr int first_column = 0;
  static constexpr std::size_t maximum_paths = 4096;
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
      throw Failure{"RepositoryHistoryUnavailable"};
    }
    return reinterpret_cast<Function>(address);
  }

  void prepare(const char *sql) {
    if (statement_) {
      finalize_(std::exchange(statement_, nullptr));
    }
    constexpr int null_terminated = -1;
    if (prepare_(database_, sql, null_terminated, &statement_, nullptr) != Result::ok) {
      throw Failure{"RepositoryHistoryUnavailable"};
    }
  }

  void release() noexcept {
    if (statement_) {
      finalize_(statement_);
      statement_ = nullptr;
    }
    if (database_) {
      close_(database_);
      database_ = nullptr;
    }
    if (library_) {
      ::dlclose(library_);
      library_ = nullptr;
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

template <Allocator Memory, typename Consumer>
void historyPaths(Memory &memory, std::string_view socket, Consumer &&consume) {
  ServerOptions options;
  options.socket = socket;
  RuntimePaths paths{memory, options, ProcessEnvironment{}};
  paths.resolveStorage(options, ProcessEnvironment{});
  std::error_code error;
  const bool exists = std::filesystem::exists(std::string_view{paths.history}, error);
  if (error) {
    throw Failure{"RepositoryHistoryUnavailable"};
  }
  if (!exists) {
    return;
  }
  HistoryPathReader reader{paths.history.c_str()};
  reader.each(std::forward<Consumer>(consume));
}

}
