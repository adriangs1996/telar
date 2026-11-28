export module telar.cli.commands.history;

import std;
import telar.tbc;

import telar.cli.console.command_limit;

import telar.platform.paths;

import telar.wire.vocabulary;
import telar.platform.primitives;
import telar.cli.session.runtime_observer;
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
        export_history,
      };
      enum class ImportKind : std::uint8_t {
        automatic,
        zsh,
        bash,
        fish,
        nushell,
        xonsh,
        powershell,
        atuin,
        mcfly,
        histdb,
      };
      // How list, search and export print each entry.
      enum class Output : std::uint8_t {
        text,
        json,
        format,
        zsh,
        bash,
        fish,
      };
      static constexpr std::uint16_t default_limit = 20;
      static constexpr std::uint16_t max_results = 1000;
      static constexpr std::uint8_t max_ngram_size = 10;
      Action action;
      ImportKind import_kind = ImportKind::automatic;
      ds::Option<std::string_view> import_file = ds::none;
      std::uint64_t id = 0;
      std::int64_t before_ms = 0;
      std::uint16_t period_days = 0;
      // `--period today`: since local midnight rather than a number of days.
      bool period_today = false;
      std::uint8_t ngram_size = 1;
      bool dry_run = false;
      bool assume_yes = false;
      // `prune --filters`: the entries today's history filters would refuse.
      bool prune_filters = false;
      std::string_view query;
      HistoryScope scope = HistoryScope::global;
      tbc::val_a<std::string_view> scope_value;
      std::uint64_t pane_id = 0;
      bool failed_only = false;
      HistoryAuthorFilter author = HistoryAuthorFilter::all;
      std::uint16_t limit = default_limit;
      std::uint32_t offset = 0;
      // `--after ID`: a listing by time continues past that entry, the last one the previous
      // page showed, so what was deleted or recorded meanwhile neither skips nor repeats any.
      std::uint64_t after_id = 0;
      // `prune --keep N`: only the older runs past the newest N of each command go.
      std::uint32_t keep_runs = 0;
      bool distinct = false;
      Output output = Output::text;
      std::string_view format;
      ds::Option<std::string_view> socket = ds::none;
      // The filters --since, --until, --exit, --min-duration, --host, --branch and --shell set,
      // and the order and mode --sort and --mode choose.
      std::int64_t since_ms = 0;
      std::int64_t until_ms = 0;
      ds::Option<std::int32_t> exit_code = ds::none;
      std::uint64_t min_duration_ms = 0;
      std::string_view host;
      std::string_view branch;
      std::string_view shell;
      HistorySort sort = HistorySort::automatic;
      HistoryMatch match = HistoryMatch::substring;

      void setScope(HistoryScope value, tbc::val_a<std::string_view> path = {});

      static ImportKind importKind(std::string_view value);

      static std::int64_t parseBefore(std::string_view text);

      // A time as --since and --until take it, in milliseconds: `today`, `yesterday`, an age
      // before `now_ms` as `-1d`, `2h`, `30m`, `90s` or `1w`, a date as YYYY-MM-DD, or seconds
      // since the epoch.
      static std::int64_t parseTime(std::string_view text, std::int64_t now_ms);

      // A duration as --min-duration takes it: `500ms`, `2s`, `5m`, `1h`, or milliseconds.
      static std::uint64_t parseDuration(std::string_view text);

      static HistoryOptions parse(Arguments words);
    };

  }
}

// Interface: history.cppm
export {
  namespace telar::runtime::cli::history {

    int run(Memory& memory, const HistoryOptions& options);

  }
}
