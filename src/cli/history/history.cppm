export module telar.cli.history;

import std;
import telar.tbc;

export import telar.cli.command_limit;

export import telar.platform.paths;

import telar.base.diagnostics;
import telar.wire.vocabulary;
import telar.wire.history;
import telar.wire.runtime;
import telar.platform.primitives;
import telar.cli.runtime_observer;
import telar.cli.server;
import telar.platform.error;
import telar.platform.fs;
import telar.cli.control_session;

// Interface: diagnostics_options.cppm
export {
  namespace telar::runtime::cli {

    struct DiagnosticsOptions {
      enum class Action {
        logs,
        limits,
      };
      enum class Component {
        all,
        runtime,
        client,
      };
      static constexpr std::uint16_t default_lines = 100;
      static constexpr std::uint16_t max_lines = 10000;
      Action action;
      Component component = Component::all;
      std::optional<std::uint32_t> pid = std::nullopt;
      std::uint16_t lines = default_lines;
      bool json = false;
      std::optional<std::string_view> socket = std::nullopt;

      static DiagnosticsOptions parse(Arguments words);
    };

  }
}

// Interface: file_transfer.cppm
export {
#ifdef __linux__
#endif

  namespace telar::runtime::cli::file_transfer {

    inline constexpr std::size_t copy_buffer_bytes = 64 * 1024;

    struct Options {
      enum class Action {
        put,
        get,
      };
      Action action;
      std::string path;
      std::uint64_t bytes = 0;

      static Options parse(Arguments words);
    };

    // Walk with directory descriptors: no ancestor, including the final parent,
    // may redirect a transfer through a symlink between validation and opening.
    FileDescriptor openDirectory(std::string_view path, bool create = false);

    FileDescriptor openParent(std::string_view path);

    FileDescriptor openRegular(int parent, const char* name);

    std::uint64_t copy(int input, int output);

    void publish(int parent, const char* temporary, const char* name);

    void transfer(const Options& options);

    int run(const Options& options);

  }
}

// Interface: diagnostics.cppm
export {
  namespace telar::runtime::cli::diagnostics {

    template <Allocator Memory>
    int run(Memory& memory, const DiagnosticsOptions& options);
    extern template int run<Memory>(Memory& memory, const DiagnosticsOptions& options);

  }
}

// Interface: ensure_runtime.cppm
export {
  namespace telar::runtime::cli {

    // Connects to the runtime, starting it when none listens. Commands that only
    // report must never resurrect a stopped runtime and do not call this.
    template <Allocator Memory>
    void ensureRuntime(Memory& memory, const RuntimePaths<Memory>& paths, const ServerOptions& options = {});
    extern template void ensureRuntime<Memory>(Memory& memory, const RuntimePaths<Memory>& paths, const ServerOptions& options);

  }
}

// Interface: history_options.cppm
export {
  namespace telar::runtime::cli {

    struct HistoryOptions {
      enum class Action {
        import,
        remove,
        prune,
        show,
        stats,
        list,
        search,
      };
      enum class ImportKind {
        automatic,
        zsh,
        bash,
        fish,
      };
      static constexpr std::uint16_t default_limit = 20;
      static constexpr std::uint16_t max_results = 1000;
      Action action;
      ImportKind import_kind = ImportKind::automatic;
      std::optional<std::string_view> import_file = std::nullopt;
      std::uint64_t id = 0;
      std::int64_t before_ms = 0;
      std::uint16_t period_days = 0;
      bool dry_run = false;
      bool assume_yes = false;
      std::string_view query;
      HistoryScope scope = HistoryScope::global;
      tbc::view<std::string_view, tbc::lt::a> scope_value;
      std::uint64_t pane_id = 0;
      bool failed_only = false;
      HistoryAuthorFilter author = HistoryAuthorFilter::all;
      std::uint16_t limit = default_limit;
      std::optional<std::string_view> socket = std::nullopt;

      void setScope(HistoryScope value, tbc::view<std::string_view, tbc::lt::a> path = {});

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
    template <Allocator Memory>
    tbc::view<HistoryResults, tbc::lt::b> query(tbc::view<ControlSession<Memory>&, tbc::lt::b> session, const HistoryOptions& options, const HistoryScopeValue& scope);

    template <Allocator Memory>
    void prune(Memory& memory, const char* socket, ControlSession<Memory>& session, const HistoryOptions& options, const HistoryScopeValue& scope);

    template <Allocator Memory>
    void show(ControlSession<Memory>& session, const HistoryOptions& options);

    template <Allocator Memory>
    void stats(ControlSession<Memory>& session, const HistoryOptions& options, const HistoryScopeValue& scope);

    template <Allocator Memory>
    int run(Memory& memory, const HistoryOptions& options);
    extern template int run<Memory>(Memory& memory, const HistoryOptions& options);

  }
}
