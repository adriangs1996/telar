#pragma once

#include "../transport/encoded_reply.hpp"
#include "agent_command.hpp"
#include "import_identity.hpp"
#include "launch_writer.hpp"
#include "pane_writer.hpp"
#include "result_rows.hpp"
#include "schema.hpp"
#include "telar_base/history/search_policy.hpp"
#include "telar_config/history/filters.hpp"
#include <unordered_set>

namespace telar::runtime {

template <Allocator Memory>
class HistoryStore {
public:
  explicit HistoryStore(Memory &memory, const char *path, const HistoryFilters &filters = default_history_filters)
      : memory_(memory),
        filters_(filters),
        database_(path),
        rows_(memory) {
    migrateHistory(database_);
    indexed_ = enableHistoryIndex(database_);
  }

  void reportAgentCommand(const ReportAgentCommand &request, const RequestContext &context, EncodedReply<Memory> &reply) {
    if (!filters_.allowsAgent(request.command, request.cwd)) {
      reply.send(RequestCompleted{.request_id = request.request_id});
      return;
    }

    if (!agent_commands_) {
      agent_commands_.emplace(database_);
    }
    agent_commands_->persist(request, context);
    reply.send(RequestCompleted{.request_id = request.request_id});
  }

  void record(const HistoryEventView &event) {
    if (!accepts(event)) {
      return;
    }

    if (event.kind == HistoryEventKind::launch_failed) {
      if (!launch_writer_) {
        launch_writer_.emplace(database_);
      }

      launch_writer_->persist(event);
      return;
    }

    if (!pane_writer_) {
      pane_writer_.emplace(database_);
    }

    pane_writer_->persist(event);
  }

  bool accepts(const HistoryEventView &event) const noexcept {
    return event.kind != HistoryEventKind::command_finished || filters_.allowsPane(event.command.command, event.command.directory);
  }

  void importEntries(const ImportHistory &request, EncodedReply<Memory> &reply) {
    const auto sequence = integer(request.base_sequence);
    if (request.entries.size() > static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max() - sequence)) {
      throw RequestError{FailureCode::invalid_request, "History import sequence overflows"};
    }

    const ImportIdentity identity{request.source};
    Transaction transaction{database_};
    Statement session{database_, "INSERT OR IGNORE INTO session(id, pane_id, location_kind, location_id, tab_id, workspace_path, shell, started_at_ms) VALUES(?1, ?2, 0, ?2, ?2, '', ?3, ?4)"};
    session.bind(1, std::span{identity.session});
    session.bind(2, integer(identity.pane));
    session.bind(3, request.source);
    session.bind(4, request.entries.front().started_at_ms);
    session.finish();

    Statement command{database_, "INSERT OR IGNORE INTO command(session_id, pane_id, location_kind, location_id, tab_id, sequence, command, cwd, workspace_path, started_at_ms, duration_ns, exit_code, status, author, origin) VALUES(?1, ?2, 0, ?2, ?2, ?3, ?4, '', '', ?5, 0, NULL, 0, 0, 0)"};
    for (std::size_t index = 0; index < request.entries.size(); ++index) {
      command.bind(1, std::span{identity.session});
      command.bind(2, integer(identity.pane));
      command.bind(3, sequence + static_cast<std::int64_t>(index));
      command.bind(4, request.entries[index].command);
      command.bind(5, request.entries[index].started_at_ms);
      command.finish();
      command.reset();
    }

    transaction.commit();
    reply.send(RequestCompleted{.request_id = request.request_id});
  }

  void query(QueryHistory request, EncodedReply<Memory> &reply) {
    rows_.clear();
    if (request.snapshot_id == 0) {
      Statement boundary{database_, "SELECT COALESCE(MAX(id), 0) FROM command"};
      checkRow(boundary);
      request.snapshot_id = static_cast<std::uint64_t>(boundary.integer(0));
    }

    if (request.match == HistoryMatch::fuzzy && !request.query.empty() && request.entry_id == 0) {
      queryFuzzy(request, reply);
      return;
    }

    auto sql = string("SELECT ");
    sql += entry_columns;
    sql += " FROM command WHERE id <= ?1";
    if (request.entry_id != 0) {
      sql += " AND id = ?2";
    }
    appendMatch(sql, request.query);
    appendFilters(sql, request);
    sql += " ORDER BY started_at_ms DESC, id DESC LIMIT ?7 OFFSET ?8";
    Statement statement{database_, sql};
    statement.bind(1, integer(request.snapshot_id));
    if (request.entry_id != 0) {
      statement.bind(2, integer(request.entry_id));
    }
    bindMatch(statement, request.query);
    bindFilters(statement, request);
    statement.bind(7, static_cast<std::int64_t>(request.limit) + 1);
    statement.bind(8, request.offset);

    HashSet seen{0, std::hash<std::uint64_t>{}, std::equal_to<std::uint64_t>{}, AllocatorRef<std::uint64_t, Memory>{memory_}};
    bool more = false;
    while (statement.next()) {
      if (request.distinct && !seen.insert(ImportIdentity::hash(command_hash_seed, statement.text(6))).second) {
        continue;
      }

      if (rows_.entries().size() == request.limit || !rows_.append(statement)) {
        more = true;
        break;
      }
    }

    reply.send(HistoryResults{.request_id = request.request_id,
                              .snapshot_id = request.snapshot_id,
                              .has_more = more,
                              .entries = rows_.entries()});
  }

  void remove(const DeleteHistory &request, EncodedReply<Memory> &reply) {
    Statement statement{database_, "DELETE FROM command WHERE id = ?1"};
    statement.bind(1, integer(request.id));
    statement.finish();
    reply.send(HistoryPruned{.request_id = request.request_id,
                             .removed = static_cast<std::uint64_t>(sqlite3_changes64(database_.handle()))});
  }

  void prune(const PruneHistory &request, EncodedReply<Memory> &reply) {
    auto sql = string("DELETE FROM command WHERE 1=1");
    appendMatch(sql, request.match);
    if (request.failed_only) {
      sql += " AND exit_code IS NOT NULL AND exit_code <> 0";
    }
    if (request.before_ms != 0) {
      sql += " AND started_at_ms < ?4";
    }
    appendScope(sql, request.scope);
    Statement statement{database_, sql};
    bindMatch(statement, request.match);
    if (request.before_ms != 0) {
      statement.bind(4, request.before_ms);
    }
    bindScope(statement, request.scope, request.scope_value);
    statement.finish();
    reply.send(HistoryPruned{.request_id = request.request_id,
                             .removed = static_cast<std::uint64_t>(sqlite3_changes64(database_.handle()))});
  }

  void readOutput(const ReadHistoryOutput &request, EncodedReply<Memory> &reply) {
    Statement statement{database_, "SELECT content, truncated, observed_bytes FROM command_output WHERE command_id = ?1"};
    statement.bind(1, integer(request.id));
    HistoryOutput result{.request_id = request.request_id,
                         .id = request.id};
    if (statement.next()) {
      const auto text = statement.text(0);
      result.content = std::span{reinterpret_cast<const Byte *>(text.data()), text.size()};
      result.truncated = statement.integer(1) != 0;
      result.observed_bytes = static_cast<std::uint64_t>(statement.integer(2));
    }

    reply.send(result);
  }

  void stats(const HistoryStatsQuery &request, EncodedReply<Memory> &reply) {
    rows_.clear();
    auto filters = string(" WHERE 1=1");
    appendScope(filters, request.scope);
    if (request.since_ms != 0) {
      filters += " AND started_at_ms >= ?1";
    }
    auto sql = string("SELECT COUNT(*), COUNT(DISTINCT command) FROM command");
    sql += filters;
    Statement totals{database_, sql};
    bindScope(totals, request.scope, request.scope_value);
    if (request.since_ms != 0) {
      totals.bind(1, request.since_ms);
    }
    checkRow(totals);
    HistoryStatsResult result{.request_id = request.request_id,
                              .total = static_cast<std::uint64_t>(totals.integer(0)),
                              .unique = static_cast<std::uint64_t>(totals.integer(1))};

    sql.assign("SELECT command, COUNT(*) AS n FROM command");
    sql += filters;
    sql += " GROUP BY command ORDER BY n DESC LIMIT 400";
    Statement top{database_, sql};
    bindScope(top, request.scope, request.scope_value);
    if (request.since_ms != 0) {
      top.bind(1, request.since_ms);
    }

    std::array<HistoryStatsEntry, maximum_stats_candidates> groups;
    std::size_t count = 0;
    while (top.next()) {
      const auto group = historyGroup(top.text(0));
      const auto occurrences = static_cast<std::uint64_t>(top.integer(1));
      const auto existing = std::span{groups}.first(count);
      auto found = std::ranges::find(existing, group, &HistoryStatsEntry::command);
      if (found != existing.end()) {
        found->count += occurrences;
      } else {
        groups[count++] = HistoryStatsEntry{.count = occurrences,
                                            .command = rows_.copy(group)};
      }
    }

    std::sort(groups.begin(), groups.begin() + count, [](const auto &left, const auto &right) {
      return left.count == right.count ? left.command < right.command : left.count > right.count;
    });
    result.top = std::span{groups}.first(std::min(count, maximum_stats_results));
    reply.send(result);
  }

private:
  static constexpr auto entry_columns = "id, pane_id, started_at_ms, duration_ns, exit_code, status, command, cwd, workspace_path, author, origin, provider, command_truncated";
  static constexpr std::uint64_t command_hash_seed = 0x74656c6172;
  static constexpr std::size_t maximum_fuzzy_candidates = 10'000;
  static constexpr std::size_t maximum_stats_candidates = 400;
  static constexpr std::size_t maximum_stats_results = 10;
  using HashSet = std::unordered_set<std::uint64_t, std::hash<std::uint64_t>, std::equal_to<std::uint64_t>, AllocatorRef<std::uint64_t, Memory>>;

  struct RankedEntry {
    std::int64_t id;
    std::uint32_t score;
    std::uint32_t order;
  };

  void queryFuzzy(const QueryHistory &request, EncodedReply<Memory> &reply) {
    auto sql = string("SELECT id, command FROM command WHERE id <= ?1");
    appendFilters(sql, request);
    sql += " ORDER BY started_at_ms DESC, id DESC LIMIT 10000";
    Statement statement{database_, sql};
    statement.bind(1, integer(request.snapshot_id));
    bindFilters(statement, request);
    Vector<RankedEntry, Memory> ranked{AllocatorRef<RankedEntry, Memory>{memory_}};
    ranked.reserve(maximum_fuzzy_candidates);
    HashSet seen{0, std::hash<std::uint64_t>{}, std::equal_to<std::uint64_t>{}, AllocatorRef<std::uint64_t, Memory>{memory_}};

    std::uint32_t order = 0;
    while (statement.next()) {
      const auto command = statement.text(1);
      if (request.distinct && !seen.insert(ImportIdentity::hash(command_hash_seed, command)).second) {
        continue;
      }

      if (const auto score = historyScore(command, request.query)) {
        ranked.push_back(RankedEntry{statement.integer(0), *score, order++});
      }
    }

    const auto precedes = [](const RankedEntry &left, const RankedEntry &right) {
      return left.score == right.score ? left.order < right.order : left.score > right.score;
    };
    const auto end = std::min(std::uint64_t{request.offset} + request.limit, static_cast<std::uint64_t>(ranked.size()));
    std::partial_sort(ranked.begin(), ranked.begin() + end, ranked.end(), precedes);
    sql.assign("SELECT ");
    sql += entry_columns;
    sql += " FROM command WHERE id = ?1";
    Statement detail{database_, sql};
    const auto start = std::min<std::size_t>(request.offset, ranked.size());
    for (std::size_t index = start; index < end; ++index) {
      detail.bind(1, ranked[index].id);
      checkRow(detail);
      if (!rows_.append(detail)) {
        break;
      }
      detail.reset();
    }

    reply.send(HistoryResults{.request_id = request.request_id,
                              .snapshot_id = request.snapshot_id,
                              .has_more = start + rows_.entries().size() < ranked.size(),
                              .entries = rows_.entries()});
  }

  String<Memory> string(std::string_view value) const {
    return String<Memory>{value, AllocatorRef<char, Memory>{memory_}};
  }

  static std::int64_t integer(std::uint64_t value) {
    if (value > static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) {
      throw RequestError{FailureCode::invalid_request, "History identity exceeds the database integer range"};
    }
    return static_cast<std::int64_t>(value);
  }

  static void checkRow(Statement &statement) {
    if (!statement.next()) {
      throw RequestError{FailureCode::internal, "Expected history row is absent"};
    }
  }

  bool useIndex(std::string_view query) const noexcept {
    std::size_t characters = 0;
    for (const unsigned char byte : query) {
      characters += (byte & 0xc0) != 0x80;
    }
    return indexed_ && characters >= 3;
  }

  void appendMatch(String<Memory> &sql, std::string_view query) const {
    if (!query.empty()) {
      sql += useIndex(query) ? " AND id IN (SELECT rowid FROM command_fts WHERE command_fts MATCH ?3)" : " AND instr(lower(command), lower(?3)) > 0";
    }
  }

  void bindMatch(Statement &statement, std::string_view query) const {
    if (query.empty()) {
      return;
    }
    if (!useIndex(query)) {
      statement.bind(3, query);
      return;
    }

    auto quoted = string("\"");
    for (const char byte : query) {
      quoted += byte;
      if (byte == '"') {
        quoted += '"';
      }
    }
    quoted += '"';
    statement.bind(3, std::string_view{quoted});
  }

  static void appendScope(String<Memory> &sql, HistoryScope scope) {
    switch (scope) {
    case HistoryScope::global:
      break;
    case HistoryScope::cwd:
      sql += " AND cwd = ?6";
      break;
    case HistoryScope::workspace:
      sql += " AND workspace_path = ?6";
      break;
    case HistoryScope::pane:
      sql += " AND pane_id = ?6";
      break;
    }
  }

  static void bindScope(Statement &statement, HistoryScope scope, const HistoryScopeValue &value) {
    if (scope == HistoryScope::pane) {
      statement.bind(6, integer(std::get<std::uint64_t>(value)));
    } else if (scope != HistoryScope::global) {
      statement.bind(6, std::get<std::string_view>(value));
    }
  }

  static void appendFilters(String<Memory> &sql, const QueryHistory &request) {
    if (request.failed_only) {
      sql += " AND exit_code IS NOT NULL AND exit_code <> 0";
    }
    if (request.author != HistoryAuthorFilter::all) {
      sql += " AND author = ?5";
    }
    appendScope(sql, request.scope);
  }

  static void bindFilters(Statement &statement, const QueryHistory &request) {
    if (request.author != HistoryAuthorFilter::all) {
      statement.bind(5, static_cast<std::int64_t>(request.author == HistoryAuthorFilter::agent));
    }
    bindScope(statement, request.scope, request.scope_value);
  }

  Memory &memory_;
  const HistoryFilters &filters_;
  Database database_;
  HistoryRows<Memory> rows_;
  bool indexed_ = false;
  std::optional<AgentCommandWriter> agent_commands_;
  std::optional<PaneHistoryWriter> pane_writer_;
  std::optional<LaunchHistoryWriter> launch_writer_;
};

}
