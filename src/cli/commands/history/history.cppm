export module telar.cli.commands.history;

import std;
import telar.tbc;

import telar.cli.console.command_limit;

import telar.platform.paths;

import telar.wire.vocabulary;
import telar.wire.history;
import telar.platform.primitives;
import telar.cli.session.runtime_observer;
import telar.cli.session.control_session;
import telar.base.memory.allocators;
import telar.base.ds;

// Interface: diagnostics_options.cppm
export {
  namespace telar::runtime::cli {

    struct DiagnosticsOptions {
      enum class Action : std::uint8_t {
        logs,
        limits,
      };
      enum class Component : std::uint8_t {
        all,
        runtime,
        client,
      };
      static constexpr std::uint16_t default_lines = 100;
      static constexpr std::uint16_t max_lines = 10000;
      Action action;
      Component component = Component::all;
      ds::Option<std::uint32_t> pid = ds::none;
      std::uint16_t lines = default_lines;
      bool json = false;
      ds::Option<std::string_view> socket = ds::none;

      static DiagnosticsOptions parse(Arguments words);
    };

  }
}

// Interface: file_transfer.cppm
export {
#ifdef __linux__
#endif

  namespace telar::runtime::cli::file_transfer {

    inline constexpr std::size_t copy_buffer_bytes = std::size_t{64} * 1024;

    struct Options {
      enum class Action : std::uint8_t {
        put,
        get,
      };
      Action action;
      // Views the command line, so it ends with a NUL, as does every suffix of it.
      std::string_view path;
      std::uint64_t bytes = 0;

      static Options parse(Arguments words);
    };

    // Walk with directory descriptors: no ancestor, including the final parent,
    // may redirect a transfer through a symlink between validation and opening.
    FileDescriptor openDirectory(std::string_view path, bool create = false);

    FileDescriptor openParent(std::string_view path);

    FileDescriptor openRegular(int parent, const char* name);

    // The descriptors a copy reads and writes.
    struct CopyEnds {
      int input;
      int output;
    };

    std::uint64_t copy(CopyEnds ends);

    void publish(int parent, const char* temporary, const char* name);

    void transfer(const Options& options);

    int run(const Options& options);

  }
}

// Interface: diagnostics.cppm
export {
  namespace telar::runtime::cli::diagnostics {

    int run(Memory& memory, const DiagnosticsOptions& options);

  }
}

// Interface: ensure_runtime.cppm
export {
  namespace telar::runtime::cli {

    // Connects to the runtime, starting it when none listens. Commands that only
    // report must never resurrect a stopped runtime and do not call this.
    void ensureRuntime(Memory& memory, const RuntimePaths<Memory>& paths, const ServerOptions& options = {});

  }
}

// Interface: history_options.cppm
export {
  namespace telar::runtime::cli {

    struct HistoryOptions {
      enum class Action : std::uint8_t {
        import,
        remove,
        prune,
        show,
        stats,
        list,
        search,
      };
      enum class ImportKind : std::uint8_t {
        automatic,
        zsh,
        bash,
        fish,
      };
      static constexpr std::uint16_t default_limit = 20;
      static constexpr std::uint16_t max_results = 1000;
      Action action;
      ImportKind import_kind = ImportKind::automatic;
      ds::Option<std::string_view> import_file = ds::none;
      std::uint64_t id = 0;
      std::int64_t before_ms = 0;
      std::uint16_t period_days = 0;
      bool dry_run = false;
      bool assume_yes = false;
      std::string_view query;
      HistoryScope scope = HistoryScope::global;
      tbc::val_a<std::string_view> scope_value;
      std::uint64_t pane_id = 0;
      bool failed_only = false;
      HistoryAuthorFilter author = HistoryAuthorFilter::all;
      std::uint16_t limit = default_limit;
      ds::Option<std::string_view> socket = ds::none;

      void setScope(HistoryScope value, tbc::val_a<std::string_view> path = {});

      static ImportKind importKind(std::string_view value);

      static std::int64_t parseBefore(std::string_view text);

      static HistoryOptions parse(Arguments words);
    };

  }
}

// Interface: history.cppm
export {
  namespace telar::runtime::cli::history {

    // The results view the session; region `b` keeps them apart from the options' own `a`.
    tbc::val_b<HistoryResults> query(tbc::mut_b<ControlSession> session, const HistoryOptions& options, const HistoryScopeValue& scope);

    void prune(Memory& memory, const char* socket, ControlSession& session, const HistoryOptions& options, const HistoryScopeValue& scope);

    void show(ControlSession& session, const HistoryOptions& options);

    void stats(ControlSession& session, const HistoryOptions& options, const HistoryScopeValue& scope);

    int run(Memory& memory, const HistoryOptions& options);

  }
}
