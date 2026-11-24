export module telar.wire.history;

// Command history: queries, imports, deletion, pruning and statistics.

import std;
import telar.wire.vocabulary;

// The schemas specialize `MessageSchema`, which telar.wire.vocabulary declares in its global
// fragment; naming the template here keeps it reachable from importers.
export namespace telar {
  using telar::MessageSchema;
}

// Declared in the global module, with the vocabulary these schemas build on, so the module's
// implementation unit defines their members there too.
// NOLINTBEGIN(misc-use-internal-linkage): exported, and declared in the global module as the vocabulary is.
export extern "C++" {
  namespace telar {

    struct QueryHistory {
      static constexpr std::size_t maximum_query_bytes = 1024;
      static constexpr std::uint16_t maximum_limit = 1000;

      std::uint64_t request_id{};
      std::string_view query;
      HistoryScope scope{};
      HistoryScopeValue scope_value;
      bool failed_only{};
      HistoryAuthorFilter author{};
      HistoryMatch match{};
      bool distinct{};
      std::uint16_t limit{};
      std::uint32_t offset{};
      std::uint64_t snapshot_id{};
      std::uint64_t entry_id{};
    };

    template <>
    struct MessageSchema<QueryHistory>
        : Schema<Direction::client, ClientTag::query_history, Field<&QueryHistory::request_id, NonzeroU64, "request_id">, Field<&QueryHistory::query, Text16<QueryHistory::maximum_query_bytes>, "query">, Field<&QueryHistory::scope, EnumByte<HistoryScope, 3>, "scope">, ContextField<&QueryHistory::scope_value, &QueryHistory::scope, ScopedHistoryValue, "scope_value">, Field<&QueryHistory::failed_only, BoolByte, "failed_only">, Field<&QueryHistory::author, EnumByte<HistoryAuthorFilter, 2>, "author">, Field<&QueryHistory::match, EnumByte<HistoryMatch, 1>, "match">, Field<&QueryHistory::distinct, BoolByte, "distinct">, Field<&QueryHistory::limit, BoundedInteger<u16, 1, QueryHistory::maximum_limit>, "limit">, Field<&QueryHistory::offset, u32, "offset">, Field<&QueryHistory::snapshot_id, u64, "snapshot_id">, Field<&QueryHistory::entry_id, u64, "entry_id">> {};

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
    };

    template <>
    struct MessageSchema<PruneHistory>
        : Schema<Direction::client, ClientTag::prune_history, Field<&PruneHistory::request_id, NonzeroU64, "request_id">, Field<&PruneHistory::scope, EnumByte<HistoryScope, 3>, "scope">, ContextField<&PruneHistory::scope_value, &PruneHistory::scope, ScopedHistoryValue, "scope_value">, Field<&PruneHistory::before_ms, i64, "before_ms">, Field<&PruneHistory::failed_only, BoolByte, "failed_only">, Field<&PruneHistory::match, Text16<PruneHistory::maximum_match_bytes>, "match">> {};

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
// NOLINTEND(misc-use-internal-linkage)
