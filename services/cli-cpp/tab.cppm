module;
#include "tbc/view.hpp"
#include <stdlib.h>
#include <new>

#include <cstdint>

#include <cerrno>
#include <unistd.h>
#include <climits>
#include <dlfcn.h>

#include <cstddef>
#include <cstring>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <cstdio>
#include <cstdlib>
#include <limits.h>
#if (defined(__APPLE__))
#include <mach-o/dyld.h>
#endif
#include <fcntl.h>
#include <sys/stat.h>
#include <csignal>
#include <dirent.h>
#include <spawn.h>
#include <sys/wait.h>
#include <pwd.h>

export module telar.cli.tab;

import std;

export import telar.cli.window;


export import telar.cli.command_limit;


export import telar.config;


export import telar.cli.worktree_git;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;

// Interface: config_check.cppm
export {
namespace telar::runtime::cli {

int checkConfiguration(const window::ConfigCheckOptions &options);

}
}

// Interface: history_paths.cppm
export {
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
  inline bool open(const char *path) {
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

  inline ~HistoryPathReader() {
    release();
  }

  HistoryPathReader(const HistoryPathReader &) = delete;
  HistoryPathReader &operator=(const HistoryPathReader &) = delete;

  // A new runtime can accept clients while its history worker still creates
  // the schema: no session table means no recorded paths.
  template <typename Consumer>
  inline void each(Consumer &&consume) {
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
  inline Function symbol(const char *name) {
    const auto address = ::dlsym(library_, name);
    if (!address) {
      throw std::runtime_error{"RepositoryHistoryUnavailable"};
    }

    return reinterpret_cast<Function>(address);
  }

  inline void prepare(const char *sql) {
    if (statement_) {
      finalize_(std::exchange(statement_, nullptr));
    }

    constexpr int null_terminated = -1;
    if (prepare_(database_, sql, null_terminated, &statement_, nullptr) != Result::ok) {
      throw std::runtime_error{"RepositoryHistoryUnavailable"};
    }
  }

  inline void release() noexcept {
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
  // Functions of the library library_ holds open.
  tbc::view<Open, tbc::lt::self> open_{};
  tbc::view<Close, tbc::lt::self> close_{};
  tbc::view<Prepare, tbc::lt::self> prepare_{};
  tbc::view<Finalize, tbc::lt::self> finalize_{};
  tbc::view<Step, tbc::lt::self> step_{};
  tbc::view<Text, tbc::lt::self> text_{};
  tbc::view<Length, tbc::lt::self> length_{};
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
}

// Interface: integration_options.cppm
export {
namespace telar::runtime::cli {

enum class IntegrationAction { install,
                               uninstall,
                               status };

struct IntegrationOptions {
  IntegrationAction action = IntegrationAction::status;
  AgentProvider provider = AgentProvider::unknown;
  std::string_view settings;
  bool legacy = false;

  // Zig's `IntegrationOptions.parse`, with its error names.
  inline static IntegrationOptions parse(std::span<char *const> arguments) {
    if (arguments.size() < 2) {
      usage("MissingIntegrationArguments");
    }

    IntegrationOptions options;
    const std::string_view action = arguments[0];
    if (action == "install") {
      options.action = IntegrationAction::install;
    } else if (action == "uninstall") {
      options.action = IntegrationAction::uninstall;
    } else if (action != "status") {
      usage("UnknownIntegrationAction");
    }

    options.provider = providerNamed(arguments[1]);
    if (options.provider == AgentProvider::unknown) {
      usage("UnknownHookAgent");
    }

    for (std::size_t index = 2; index < arguments.size(); ++index) {
      const std::string_view option = arguments[index];
      if (option == "--legacy" && options.action == IntegrationAction::uninstall) {
        options.legacy = true;
        continue;
      }

      if (option != "--settings" || index + 1 >= arguments.size()) {
        usage("UnknownIntegrationOption");
      }

      options.settings = arguments[++index];
      if (!options.settings.starts_with('/')) {
        usage("RelativeSettingsPath");
      }
    }

    if (options.legacy && !options.settings.empty()) {
      usage("UnknownIntegrationOption");
    }

    return options;
  }
};

}
}

// Interface: integration.cppm
export {
namespace telar::runtime::cli {

int runIntegration(BudgetAllocator<SystemAllocator> &memory, const IntegrationOptions &options);

}
}

// Interface: tab.cppm
export {
namespace telar::runtime::cli::sessions {

template <Allocator Memory>
void tabSnapshot(Output<Memory> &output, const TabSnapshot &reply, bool json) {
  if (json) {
    output.text("{\"workspace_id\":").number(reply.location.workspace.id).text(",\"tab_id\":").number(reply.location.tab_id).text(",\"panes\":[");
  } else {
    output.text("PANE\tGENERATION\tLIFECYCLE\n");
  }

  bool first = true;
  for (const auto &pane : reply.panes) {
    const auto lifecycle = pane.lifecycle == PaneLifecycle::running ? "running" : "exited";
    if (json) {
      if (!first) {
        output.text(",");
      }
      output.text("{\"pane_id\":").number(pane.pane_id).text(",\"pane_generation\":").number(pane.pane_generation).text(",\"lifecycle\":").json(lifecycle).text("}");
    } else {
      output.number(pane.pane_id).text("\t").number(pane.pane_generation).text("\t").text(lifecycle).text("\n");
    }
    first = false;
  }

  if (json) {
    output.text("]}\n");
  }
}

template <Allocator Memory>
void tabList(Output<Memory> &output, const WorkspaceSnapshot &reply, bool json) {
  output.text(json ? "[" : "ID\tPOSITION\tPANES\tLABEL\n");
  bool first = true;
  for (const auto &entry : reply.tabs) {
    if (json) {
      if (!first) {
        output.text(",");
      }
      output.text("{\"workspace_id\":").number(reply.workspace.id).text(",\"tab_id\":").number(entry.tab_id).text(",\"position\":").number(entry.position).text(",\"pane_count\":").number(entry.pane_count).text(",\"label\":").json(entry.label).text("}");
    } else {
      output.number(entry.tab_id).text("\t").number(entry.position).text("\t").number(entry.pane_count).text("\t").text(entry.label).text("\n");
    }
    first = false;
  }

  if (json) {
    output.text("]\n");
  }
}

template <Allocator Memory>
void tabOperation(Channel<Memory> &session, Output<Memory> &output, const TabOptions &options, TabLocation location) {
  using Action = TabOptions::Action;
  if (options.action == Action::get) {
    const auto reply = session.template exchange<TabSnapshot>(RequestTabSnapshot{.location = location});
    checkLocation(reply.location, location);
    tabSnapshot(output, reply, options.json);
    return;
  }

  if (options.json) {
    output.text("{\"workspace_id\":").number(location.workspace.id).text(",\"tab_id\":").number(location.tab_id);
  } else {
    output.text("tab ").number(location.tab_id);
  }

  switch (options.action) {
  case Action::rename: {
    wireTabLabel(*options.label);
    const auto reply = session.template exchange<TabRenamed>(RenameTab{.location = location, .label = *options.label});
    checkLocation(reply.location, location);
    if (options.json) {
      output.text(",\"label\":").json(reply.label);
    } else {
      output.text(" renamed to ").text(reply.label);
    }
    break;
  }
  case Action::close: {
    const auto reply = session.template exchange<TabClosed>(CloseTab{.location = location});
    checkLocation(reply.location, location);
    if (options.json) {
      output.text(",\"closed\":true,\"workspace_closed\":").boolean(reply.workspace_closed);
    } else {
      output.text(" closed");
    }
    break;
  }
  case Action::move: {
    const auto reply = session.template exchange<TabMoved>(MoveTab{.location = location, .direction = options.direction, .relative_to = options.relative});
    checkLocation(reply.location, location);
    output.text(options.json ? ",\"position\":" : " moved to position ").number(reply.position);
    break;
  }
  default:
    throw Failure{"InvalidTabAction"};
  }

  output.text(options.json ? "}\n" : "\n");
}

template <Allocator Memory>
int tab(Memory &memory, const TabOptions &options) {
  try {
    const auto workspace = options.workspace.resolve("TELAR_WORKSPACE_ID");
    Channel session{memory, options.socket, false};
    Output output{memory};
    if (options.action == TabOptions::Action::create) {
      Channel catalog_session{memory, options.socket, false};
      const auto catalog = catalog_session.catalog();
      const auto entry = std::ranges::find(catalog.entries, workspace, &WorkspaceListEntry::workspace);
      if (entry == catalog.entries.end()) {
        throw Failure{"workspace not found"};
      }
      const std::array shell{loginShell()};
      wireTabLabel(options.label.value_or(""), true);
      const auto opened = session.template exchange<PaneOpened>(LaunchTab{.workspace = workspace, .label = options.label.value_or(""), .size = launch_size, .launch = {.cwd = entry->path, .arguments = shell}});
      if (options.json) {
        output.text("{\"workspace_id\":").number(workspace).text(",\"tab_id\":").number(opened.location.tab_id).text(",\"pane_id\":").number(opened.pane_id).text(",\"pane_generation\":").number(opened.pane_generation).text("}\n");
      } else {
        output.text("tab ").number(opened.location.tab_id).text(" opened in workspace ").number(workspace).text(": pane ").number(opened.pane_id).text("\n");
      }
    } else if (options.action == TabOptions::Action::list) {
      const auto reply = session.template exchange<WorkspaceSnapshot>(RequestWorkspaceSnapshot{.workspace = {.id = workspace}});
      if (reply.workspace.kind != WorkspaceLocation::Kind::workspace || reply.workspace.id != workspace) {
        throw Failure{"unexpected reply from the runtime"};
      }
      tabList(output, reply, options.json);
    } else {
      const TabLocation location{.workspace = {.id = workspace}, .tab_id = options.target.resolve("TELAR_TAB_ID")};
      tabOperation(session, output, options, location);
    }

    output.flush();
    return 0;
  } catch (const Failure &error) {
    std::fprintf(stderr, "telar tab: %s\n", error.what());
    return error.status();
  } catch (const std::exception &error) {
    std::fprintf(stderr, "telar tab: %s\n", error.what());
    return 1;
  }
}

}
}
