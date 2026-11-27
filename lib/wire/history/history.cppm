export module telar.wire.history;

// Command history: queries, imports, deletion, pruning and statistics.

import std;
import telar.wire.vocabulary;
import telar.base.ds;

// The schemas specialize `MessageSchema`, which telar.wire.vocabulary declares in its global
// fragment; naming the template here keeps it reachable from importers.
export namespace telar {
  using telar::MessageSchema;
}

export {
  namespace telar {

    // A page of the history. Every filter that is set narrows it; each left at its default lets
    // every run through. Answered with HistoryResults. The fields after entry_id since cqp00015.
    struct QueryHistory {
      static constexpr std::size_t maximum_query_bytes = 1024;
      static constexpr std::uint16_t maximum_limit = 1000;
      static constexpr std::uint8_t maximum_neighbours = 8;

      std::uint64_t request_id{};
      std::string_view query;
      HistoryScope scope{};
      HistoryScopeValue scope_value;
      // Runs that ended with a status other than 0 and were not interrupted.
      bool failed_only{};
      HistoryAuthorFilter author{};
      HistoryMatch match{};
      bool distinct{};
      std::uint16_t limit{};
      // Into a ranked listing; a listing by time pages by `after_*` instead when it is set.
      std::uint32_t offset{};
      std::uint64_t snapshot_id{};
      std::uint64_t entry_id{};
      HistorySort sort{};
      // The runs that started in [since_ms, until_ms), each 0 when open.
      std::int64_t since_ms{};
      std::int64_t until_ms{};
      // Runs that ended with exactly this status.
      ds::Option<std::int32_t> exit_code;
      std::uint64_t min_duration_ms{};
      // Each empty for any.
      std::string_view host;
      std::string_view branch;
      std::string_view shell;
      // With the pane scope: also every run from before the pane started, as a shell's own
      // history holds what came before it.
      bool preload{};
      // Matches the captured output of each run instead of its command.
      bool output{};
      // A listing by time that also shows up to this many runs around each match, which do not
      // match themselves.
      std::uint8_t neighbours{};
      // The pane and the directory that ask, which weigh a ranked listing; 0 and empty for none.
      std::uint64_t origin_pane{};
      std::string_view origin_cwd;
      // A listing by time continues past this run, the last one the previous page showed.
      std::int64_t after_started_ms{};
      std::uint64_t after_id{};
    };

    template <>
    struct MessageSchema<QueryHistory>
        : Schema<Direction::client, ClientTag::query_history, Field<&QueryHistory::request_id, NonzeroU64, "request_id">, Field<&QueryHistory::query, Text16<QueryHistory::maximum_query_bytes>, "query">, Field<&QueryHistory::scope, EnumByte<HistoryScope, 3>, "scope">, ContextField<&QueryHistory::scope_value, &QueryHistory::scope, ScopedHistoryValue, "scope_value">, Field<&QueryHistory::failed_only, BoolByte, "failed_only">, Field<&QueryHistory::author, EnumByte<HistoryAuthorFilter, 2>, "author">, Field<&QueryHistory::match, EnumByte<HistoryMatch, 3>, "match">, Field<&QueryHistory::distinct, BoolByte, "distinct">, Field<&QueryHistory::limit, BoundedInteger<u16, 1, QueryHistory::maximum_limit>, "limit">, Field<&QueryHistory::offset, u32, "offset">, Field<&QueryHistory::snapshot_id, u64, "snapshot_id">, Field<&QueryHistory::entry_id, u64, "entry_id">, Field<&QueryHistory::sort, EnumByte<HistorySort, 2>, "sort">, Field<&QueryHistory::since_ms, i64, "since_ms">, Field<&QueryHistory::until_ms, i64, "until_ms">, Field<&QueryHistory::exit_code, OptionalValue<i32>, "exit_code">, Field<&QueryHistory::min_duration_ms, u64, "min_duration_ms">, Field<&QueryHistory::host, Text16<max_history_host_bytes>, "host">, Field<&QueryHistory::branch, Text16<max_branch_bytes>, "branch">, Field<&QueryHistory::shell, Text16<max_history_shell_bytes>, "shell">, Field<&QueryHistory::preload, BoolByte, "preload">, Field<&QueryHistory::output, BoolByte, "output">, Field<&QueryHistory::neighbours, BoundedInteger<u8, 0, QueryHistory::maximum_neighbours>, "neighbours">, Field<&QueryHistory::origin_pane, u64, "origin_pane">, Field<&QueryHistory::origin_cwd, Text16<max_path_bytes>, "origin_cwd">, Field<&QueryHistory::after_started_ms, i64, "after_started_ms">, Field<&QueryHistory::after_id, u64, "after_id">> {};

    struct ImportHistory {
      static constexpr std::size_t maximum_source_bytes = 256;
      static constexpr std::size_t maximum_entries = 64;

      std::uint64_t request_id{};
      std::string_view source;
      std::uint64_t base_sequence{};
      std::span<const ImportHistoryEntry> entries;
    };

    template <>
    struct MessageSchema<ImportHistory>
        : Schema<Direction::client, ClientTag::import_history, Field<&ImportHistory::request_id, NonzeroU64, "request_id">, Field<&ImportHistory::source, Text16<ImportHistory::maximum_source_bytes, false>, "source">, Field<&ImportHistory::base_sequence, u64, "base_sequence">, SpanCountField<&ImportHistory::entries, u16, ValueCodec<ImportHistoryEntry>, ImportHistory::maximum_entries, "entry_count", 1>, SpanItemsField<&ImportHistory::entries, ValueCodec<ImportHistoryEntry>, "entries">> {
    };

    struct DeleteHistory {
      std::uint64_t request_id{};
      std::uint64_t id{};
    };

    template <>
    struct MessageSchema<DeleteHistory>
        : Schema<Direction::client, ClientTag::delete_history, Field<&DeleteHistory::request_id, NonzeroU64, "request_id">, Field<&DeleteHistory::id, NonzeroU64, "id">> {};

    // Deletes every run of the command entry `id` ran, as a list of each command once shows it.
    // Answered with HistoryPruned. Since cqp00012.
    struct DeleteHistoryCommand {
      std::uint64_t request_id{};
      std::uint64_t id{};
    };

    template <>
    struct MessageSchema<DeleteHistoryCommand>
        : Schema<Direction::client, ClientTag::delete_history_command, Field<&DeleteHistoryCommand::request_id, NonzeroU64, "request_id">, Field<&DeleteHistoryCommand::id, NonzeroU64, "id">> {};

    struct PruneHistory {
      static constexpr std::size_t maximum_match_bytes = 1024;

      std::uint64_t request_id{};
      HistoryScope scope{};
      HistoryScopeValue scope_value;
      std::int64_t before_ms{};
      bool failed_only{};
      std::string_view match;
      // Keeps only the newest this many runs of each command in each directory on each machine,
      // as `atuin history dedup --dupkeep`; 0 keeps every run. Since cqp00015.
      std::uint32_t keep_runs{};
      // Counts what the prune would remove, removing nothing, in `removed`. Since cqp00015.
      bool dry_run{};
    };

    template <>
    struct MessageSchema<PruneHistory>
        : Schema<Direction::client, ClientTag::prune_history, Field<&PruneHistory::request_id, NonzeroU64, "request_id">, Field<&PruneHistory::scope, EnumByte<HistoryScope, 3>, "scope">, ContextField<&PruneHistory::scope_value, &PruneHistory::scope, ScopedHistoryValue, "scope_value">, Field<&PruneHistory::before_ms, i64, "before_ms">, Field<&PruneHistory::failed_only, BoolByte, "failed_only">, Field<&PruneHistory::match, Text16<PruneHistory::maximum_match_bytes>, "match">, Field<&PruneHistory::keep_runs, u32, "keep_runs">, Field<&PruneHistory::dry_run, BoolByte, "dry_run">> {};

    // Passes the stored entries a prune of these filters matches through the history's filters
    // as the runtime has them today: an entry they would refuse is removed, and one they would
    // keep redacted, its command or its output, is rewritten so. With dry_run it only counts.
    // Answered with HistoryRewritten. Since cqp00015.
    struct RewriteHistory {
      std::uint64_t request_id{};
      HistoryScope scope{};
      HistoryScopeValue scope_value;
      std::int64_t before_ms{};
      bool failed_only{};
      std::string_view match;
      bool dry_run{};
    };

    template <>
    struct MessageSchema<RewriteHistory>
        : Schema<Direction::client, ClientTag::rewrite_history, Field<&RewriteHistory::request_id, NonzeroU64, "request_id">, Field<&RewriteHistory::scope, EnumByte<HistoryScope, 3>, "scope">, ContextField<&RewriteHistory::scope_value, &RewriteHistory::scope, ScopedHistoryValue, "scope_value">, Field<&RewriteHistory::before_ms, i64, "before_ms">, Field<&RewriteHistory::failed_only, BoolByte, "failed_only">, Field<&RewriteHistory::match, Text16<PruneHistory::maximum_match_bytes>, "match">, Field<&RewriteHistory::dry_run, BoolByte, "dry_run">> {};

    struct HistoryRewritten {
      std::uint64_t request_id{};
      std::uint64_t removed{};
      std::uint64_t redacted{};
    };

    template <>
    struct MessageSchema<HistoryRewritten>
        : Schema<Direction::server, ServerTag::history_rewritten, Field<&HistoryRewritten::request_id, NonzeroU64, "request_id">, Field<&HistoryRewritten::removed, u64, "removed">, Field<&HistoryRewritten::redacted, u64, "redacted">> {};

    // Asks how one command's runs went: the command entry `entry_id` ran when it is set, else the
    // command whose text is `command`. Answered with HistoryCommandStats. Since cqp00015.
    struct QueryHistoryCommandStats {
      static constexpr std::uint8_t maximum_days = 90;

      std::uint64_t request_id{};
      std::uint64_t entry_id{};
      std::string_view command;
      // How many days of 24 hours to count the runs of, the last ending at `until_ms` (exclusive),
      // as a client's local midnight after today; 0 for none, and `until_ms` 0 for now.
      std::uint8_t days{};
      std::int64_t until_ms{};
    };

    template <>
    struct MessageSchema<QueryHistoryCommandStats>
        : Schema<Direction::client, ClientTag::query_history_command_stats, Field<&QueryHistoryCommandStats::request_id, NonzeroU64, "request_id">, Field<&QueryHistoryCommandStats::entry_id, u64, "entry_id">, Field<&QueryHistoryCommandStats::command, Text32<max_history_command_bytes>, "command">, Field<&QueryHistoryCommandStats::days, BoundedInteger<u8, 0, QueryHistoryCommandStats::maximum_days>, "days">, Field<&QueryHistoryCommandStats::until_ms, i64, "until_ms">> {};

    // Every run of one command the history keeps, as the inspector tells them. A command the
    // history does not keep has `found` false and every count 0.
    struct HistoryCommandStats {
      std::uint64_t request_id{};
      bool found{};
      std::uint64_t runs{};
      // The runs whose end the shell told with how long they took, and their mean, in
      // milliseconds; 0 when none.
      std::uint64_t measured{};
      std::uint64_t mean_duration_ms{};
      // The runs that ended with a status and were not interrupted, and those of them whose status
      // was 0: the success rate is succeeded / ended.
      std::uint64_t ended{};
      std::uint64_t succeeded{};
      // When the newest run started, in milliseconds since the epoch, and the status it ended with.
      std::int64_t last_started_ms{};
      ds::Option<std::int32_t> last_exit;
      // The runs that started in each of the days asked for, the oldest first.
      std::span<const std::uint32_t> per_day;
    };

    template <>
    struct MessageSchema<HistoryCommandStats>
        : Schema<Direction::server, ServerTag::history_command_stats, Field<&HistoryCommandStats::request_id, NonzeroU64, "request_id">, Field<&HistoryCommandStats::found, BoolByte, "found">, Field<&HistoryCommandStats::runs, u64, "runs">, Field<&HistoryCommandStats::measured, u64, "measured">, Field<&HistoryCommandStats::mean_duration_ms, u64, "mean_duration_ms">, Field<&HistoryCommandStats::ended, u64, "ended">, Field<&HistoryCommandStats::succeeded, u64, "succeeded">, Field<&HistoryCommandStats::last_started_ms, i64, "last_started_ms">, Field<&HistoryCommandStats::last_exit, OptionalValue<i32>, "last_exit">, Field<&HistoryCommandStats::per_day, CountedSpan<u8, u32, QueryHistoryCommandStats::maximum_days>, "per_day">> {};

    struct ReadHistoryOutput {
      std::uint64_t request_id{};
      std::uint64_t id{};
    };

    template <>
    struct MessageSchema<ReadHistoryOutput>
        : Schema<Direction::client, ClientTag::read_history_output, Field<&ReadHistoryOutput::request_id, NonzeroU64, "request_id">, Field<&ReadHistoryOutput::id, NonzeroU64, "id">> {};

    struct HistoryStatsQuery {
      std::uint64_t request_id{};
      HistoryScope scope{};
      HistoryScopeValue scope_value;
      std::int64_t since_ms{};
    };

    template <>
    struct MessageSchema<HistoryStatsQuery>
        : Schema<Direction::client, ClientTag::history_stats, Field<&HistoryStatsQuery::request_id, NonzeroU64, "request_id">, Field<&HistoryStatsQuery::scope, EnumByte<HistoryScope, 3>, "scope">, ContextField<&HistoryStatsQuery::scope_value, &HistoryStatsQuery::scope, ScopedHistoryValue, "scope_value">, Field<&HistoryStatsQuery::since_ms, i64, "since_ms">> {};

    // Asks for the workspaces the history recorded a session in. They outlive the workspaces
    // themselves, which is how a command finds the checkout of a repository whose workspace closed.
    struct QueryHistoryWorkspaces {
      std::uint64_t request_id{};
    };

    template <>
    struct MessageSchema<QueryHistoryWorkspaces>
        : Schema<Direction::client, ClientTag::query_history_workspaces, Field<&QueryHistoryWorkspaces::request_id, NonzeroU64, "request_id">> {};

    struct HistoryWorkspaces {
      static constexpr std::size_t maximum_paths = 4096;
      // The bytes of paths one reply carries: a quarter of a frame.
      static constexpr std::size_t maximum_bytes = std::size_t{1024} * 1024;

      std::uint64_t request_id{};
      // Whether the history recorded more workspaces than the reply lists.
      bool truncated{};
      // The path of each workspace, once.
      std::span<const std::string_view> paths;
    };

    template <>
    struct MessageSchema<HistoryWorkspaces>
        : Schema<Direction::server, ServerTag::history_workspaces, Field<&HistoryWorkspaces::request_id, NonzeroU64, "request_id">, Field<&HistoryWorkspaces::truncated, BoolByte, "truncated">, Field<&HistoryWorkspaces::paths, CountedSpan<u16, Text16<max_path_bytes>, HistoryWorkspaces::maximum_paths>, "paths">> {};

    // Asks the runtime to send this client a HistoryChanged each time the history changes, or to
    // stop. Answered with RequestCompleted. Since cqp00015.
    struct WatchHistory {
      std::uint64_t request_id{};
      bool watch{};
    };

    template <>
    struct MessageSchema<WatchHistory>
        : Schema<Direction::client, ClientTag::watch_history, Field<&WatchHistory::request_id, NonzeroU64, "request_id">, Field<&WatchHistory::watch, BoolByte, "watch">> {};

    // A person chose entry `id` from the history for pane `pane_id`. When the pane's next command
    // runs it unchanged in the same directory, the history counts it as chosen, which ranks it
    // higher. Answered with RequestCompleted. Since cqp00015.
    struct ChooseHistoryEntry {
      std::uint64_t request_id{};
      std::uint64_t id{};
      std::uint64_t pane_id{};
    };

    template <>
    struct MessageSchema<ChooseHistoryEntry>
        : Schema<Direction::client, ClientTag::choose_history_entry, Field<&ChooseHistoryEntry::request_id, NonzeroU64, "request_id">, Field<&ChooseHistoryEntry::id, NonzeroU64, "id">, Field<&ChooseHistoryEntry::pane_id, NonzeroU64, "pane_id">> {};

    // Sent unasked to each client that watches the history, after a change: what changed, the run
    // it concerns or 0, and a revision that grows with each change. Small, so a client refreshes
    // what it shows instead of being sent it. Since cqp00015.
    struct HistoryChanged {
      std::uint64_t revision{};
      HistoryChange change{};
      std::uint64_t entry_id{};
      std::uint64_t pane_id{};
    };

    template <>
    struct MessageSchema<HistoryChanged>
        : Schema<Direction::server, ServerTag::history_changed, Field<&HistoryChanged::revision, u64, "revision">, Field<&HistoryChanged::change, EnumByte<HistoryChange, 3>, "change">, Field<&HistoryChanged::entry_id, u64, "entry_id">, Field<&HistoryChanged::pane_id, u64, "pane_id">> {};

    struct HistoryResults {
      std::uint64_t request_id{};
      std::uint64_t snapshot_id{};
      bool has_more{};
      std::span<const HistoryEntry> entries;
    };

    template <>
    struct MessageSchema<HistoryResults>
        : Schema<Direction::server, ServerTag::history_results, Field<&HistoryResults::request_id, NonzeroU64, "request_id">, SpanCountField<&HistoryResults::entries, u16, ValueCodec<HistoryEntry>, QueryHistory::maximum_limit, "entry_count", 0>, Field<&HistoryResults::snapshot_id, u64, "snapshot_id">, Field<&HistoryResults::has_more, BoolByte, "has_more">, SpanItemsField<&HistoryResults::entries, ValueCodec<HistoryEntry>, "entries">> {};

    struct HistoryPruned {
      std::uint64_t request_id{};
      std::uint64_t removed{};
    };

    template <>
    struct MessageSchema<HistoryPruned>
        : Schema<Direction::server, ServerTag::history_pruned, Field<&HistoryPruned::request_id, NonzeroU64, "request_id">, Field<&HistoryPruned::removed, u64, "removed">> {};

    struct HistoryOutput {
      static constexpr std::size_t maximum_content_bytes = 65536;

      std::uint64_t request_id{};
      std::uint64_t id{};
      bool truncated{};
      std::uint64_t observed_bytes{};
      std::span<const Byte> content;
    };

    template <>
    struct MessageSchema<HistoryOutput>
        : Schema<Direction::server, ServerTag::history_output, Field<&HistoryOutput::request_id, NonzeroU64, "request_id">, Field<&HistoryOutput::id, u64, "id">, Field<&HistoryOutput::truncated, BoolByte, "truncated">, Field<&HistoryOutput::observed_bytes, u64, "observed_bytes">, Field<&HistoryOutput::content, SizedBytes<u32, HistoryOutput::maximum_content_bytes>, "content">> {};

    struct HistoryStatsResult {
      static constexpr std::size_t maximum_top = 10;

      std::uint64_t request_id{};
      std::uint64_t total{};
      std::uint64_t unique{};
      std::span<const HistoryStatsEntry> top;
    };

    template <>
    struct MessageSchema<HistoryStatsResult>
        : Schema<Direction::server, ServerTag::history_stats_result, Field<&HistoryStatsResult::request_id, NonzeroU64, "request_id">, Field<&HistoryStatsResult::total, u64, "total">, Field<&HistoryStatsResult::unique, u64, "unique">, SpanCountField<&HistoryStatsResult::top, u8, ValueCodec<HistoryStatsEntry>, HistoryStatsResult::maximum_top, "top_count", 0>, SpanItemsField<&HistoryStatsResult::top, ValueCodec<HistoryStatsEntry>, "top">> {};

  }
}
