module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.history.store;

import std;
import telar.native.sqlite;
import telar.tbc;
import telar.base.diagnostics;
import telar.base.history;
import telar.wire.runtime;
import telar.base.ds;

namespace telar::runtime {

  AgentCommandWriter::AgentCommandWriter(Database& database)
      : database_(database),
        session_(database, session_sql),
        finish_(database, finish_sql),
        insert_(database, insert_sql) {}

  void AgentCommandWriter::persist(const ReportAgentCommand& request, const RequestContext& context) {
    TELAR_TRACE("history.persistAgentCommand");
    if (request.phase == AgentCommandPhase::started && request.tool_call_id.empty()) {
      return;
    }

    Transaction transaction{database_};
    const auto now = context.received_at_ms != 0 ? context.received_at_ms : wallMilliseconds();

    session_.reset();
    session_.bind(1, std::span{context.history_session});
    session_.bind(2, static_cast<std::int64_t>(request.pane_id));
    session_.bind(3, static_cast<std::int64_t>(context.location.workspace.kind));
    session_.bind(4, static_cast<std::int64_t>(context.location.workspace.id));
    session_.bind(5, static_cast<std::int64_t>(context.location.tab_id));
    session_.bind(6, context.workspace_path);
    session_.bind(7, now);
    session_.finish();

    if (request.phase == AgentCommandPhase::finished && !request.tool_call_id.empty()) {
      finish_.reset();
      finish_.bind(1, request.command);
      finish_.bind(2, request.cwd);
      finish_.bind(3, now);
      if (request.exit_code) {
        finish_.bind(4, *request.exit_code);
      } else {
        finish_.bindNull(4);
      }

      finish_.bind(5, std::span{context.history_session});
      finish_.bind(6, request.tool_call_id);
      finish_.bind(7, context.workspace_path);
      finish_.bind(8, request.provider);
      finish_.finish();
      if (sqlite3_changes(database_.handle()) != 0) {
        transaction.commit();
        return;
      }
    }

    insert_.reset();
    insert_.bind(1, std::span{context.history_session});
    insert_.bind(2, static_cast<std::int64_t>(request.pane_id));
    insert_.bind(3, static_cast<std::int64_t>(context.location.workspace.kind));
    insert_.bind(4, static_cast<std::int64_t>(context.location.workspace.id));
    insert_.bind(5, static_cast<std::int64_t>(context.location.tab_id));
    insert_.bind(6, request.command);
    insert_.bind(7, request.cwd);
    insert_.bind(8, context.workspace_path);
    insert_.bind(9, now);
    if (request.exit_code) {
      insert_.bind(10, *request.exit_code);
    } else {
      insert_.bindNull(10);
    }

    insert_.bind(11, static_cast<std::int64_t>(request.phase == AgentCommandPhase::started ? HistoryStatus::running : HistoryStatus::completed));
    insert_.bind(12, request.provider);
    if (request.tool_call_id.empty()) {
      insert_.bindNull(13);
    } else {
      insert_.bind(13, request.tool_call_id);
    }

    insert_.finish();
    transaction.commit();
  }

  ImportIdentity::ImportIdentity(std::string_view source) noexcept {
    constexpr std::uint64_t import_seed = 0x74656c6172696d70;
    const auto low = hash(import_seed, source);
    const auto high = hash(low, source);
    static_assert(std::endian::native == std::endian::little);

    std::memcpy(session.dataMut(), &low, sizeof(low));
    std::memcpy(session.dataMut() + sizeof(low), &high, sizeof(high));
    pane = (low & ((std::uint64_t{1} << 62) - 1)) | 1;
  }

  std::uint64_t ImportIdentity::hash(std::uint64_t seed, std::string_view input) noexcept {
    constexpr ds::Array<std::uint64_t, 4> secret{0xa0761d6478bd642f, 0xe7037ed1a0b428db, 0x8ebc6af09c88c6e3, 0x589965cc75374cc3};
    ds::Array<std::uint64_t, 3> state;

    state.fill(seed ^ mix(seed ^ secret[0], secret[1]));
    std::uint64_t left = 0;
    std::uint64_t right = 0;

    if (input.size() <= 16) {
      if (input.size() >= 4) {
        const auto end = input.size() - 4;
        const auto quarter = (input.size() >> 3) << 2;

        left = (read<std::uint32_t>(input.data()) << 32) | read<std::uint32_t>(input.data() + quarter);
        right = (read<std::uint32_t>(input.data() + end) << 32) | read<std::uint32_t>(input.data() + end - quarter);
      } else if (!input.empty()) {
        left = (std::uint64_t{static_cast<unsigned char>(input.front())} << 16) | (std::uint64_t{static_cast<unsigned char>(input[input.size() >> 1])} << 8) | static_cast<unsigned char>(input.back());
      }
    } else {
      std::size_t offset = 0;

      if (input.size() >= 48) {
        while (offset + 48 < input.size()) {
          for (std::size_t lane = 0; lane < state.size(); ++lane) {
            state.atMut(lane) = mix(read<std::uint64_t>(input.data() + offset + (16 * lane)) ^ secret[lane + 1], read<std::uint64_t>(input.data() + offset + (16 * lane) + 8) ^ state[lane]);
          }

          offset += 48;
        }

        state.atMut(0) ^= state[1] ^ state[2];
      }

      while (offset + 16 < input.size()) {
        state.atMut(0) = mix(read<std::uint64_t>(input.data() + offset) ^ secret[1], read<std::uint64_t>(input.data() + offset + 8) ^ state[0]);
        offset += 16;
      }

      left = read<std::uint64_t>(input.data() + input.size() - 16);
      right = read<std::uint64_t>(input.data() + input.size() - 8);
    }

    const __uint128_t product = static_cast<__uint128_t>(left ^ secret[1]) * (right ^ state[0]);

    return mix(static_cast<std::uint64_t>(product) ^ secret[0] ^ input.size(), static_cast<std::uint64_t>(product >> 64) ^ secret[1]);
  }

  template <typename Integer>
  std::uint64_t ImportIdentity::read(const char* bytes) noexcept {
    Integer value;

    std::memcpy(&value, bytes, sizeof(value));
    return value;
  }

  std::uint64_t ImportIdentity::mix(std::uint64_t left, std::uint64_t right) noexcept {
    const __uint128_t product = static_cast<__uint128_t>(left) * right;

    return static_cast<std::uint64_t>(product) ^ static_cast<std::uint64_t>(product >> 64);
  }

  LaunchHistoryWriter::LaunchHistoryWriter(Database& database)
      : insert_(database, insert_sql) {}

  void LaunchHistoryWriter::persist(const HistoryEventView& event) {
    TELAR_TRACE("history.persistLaunchFailure");
    const auto& session = event.session;
    const auto& failure = event.failure;
    if (session.pane > std::numeric_limits<std::int64_t>::max() || failure.generation > std::numeric_limits<std::int64_t>::max() || session.location.workspace.id > std::numeric_limits<std::int64_t>::max() || session.location.tab_id > std::numeric_limits<std::int64_t>::max()) {
      throw RequestError{FailureCode::resource_limit, "History identity exceeds the database integer range"};
    }

    insert_.reset();
    insert_.bind(1, static_cast<std::int64_t>(session.pane));
    insert_.bind(2, static_cast<std::int64_t>(failure.generation));
    insert_.bind(3, static_cast<std::int64_t>(session.location.workspace.kind));
    insert_.bind(4, static_cast<std::int64_t>(session.location.workspace.id));
    insert_.bind(5, static_cast<std::int64_t>(session.location.tab_id));
    insert_.bind(6, session.workspace_path);
    insert_.bind(7, session.shell);
    insert_.bind(8, session.started_at_ms);
    insert_.bind(9, event.finished_at_ms);
    insert_.bind(10, static_cast<std::int64_t>(failure.phase));
    insert_.bind(11, failure.cause);
    insert_.finish();
  }

  PaneHistoryWriter::PaneHistoryWriter(Database& database)
      : database_(database),
        session_(database, session_sql),
        command_(database, command_sql),
        output_(database, output_sql),
        finish_(database, finish_sql),
        title_(database, title_sql) {}

  void PaneHistoryWriter::persist(const HistoryEventView& event) {
    TELAR_TRACE("history.persistPaneEvent");
    if (event.kind == HistoryEventKind::launch_failed) {
      throw RequestError{FailureCode::invalid_request, "A failed launch has no history session"};
    }

    Transaction transaction{database_};

    if (event.kind != HistoryEventKind::session_title) {
      ensureSession(event.session);
    }

    switch (event.kind) {
    case HistoryEventKind::session_started:
    case HistoryEventKind::launch_failed:
      break;
    case HistoryEventKind::session_finished:
      finish_.reset();
      finish_.bind(1, std::span{event.session.id});
      finish_.bind(2, event.finished_at_ms);
      finish_.finish();
      break;
    case HistoryEventKind::command_finished:
      insertCommand(event.session, event.command);
      break;
    case HistoryEventKind::session_title:
      title_.reset();
      title_.bind(1, std::span{event.title.session});
      title_.bind(2, event.title.title.view());
      title_.bind(3, static_cast<std::int64_t>(event.title.source));
      title_.bind(4, static_cast<std::int64_t>(event.title.state));
      title_.finish();
      if (::sqlite3_changes(database_.handle()) != 1) {
        throw RequestError{FailureCode::invalid_request, "History session does not exist"};
      }

      break;
    }

    transaction.commit();
  }

  void PaneHistoryWriter::ensureSession(const HistorySession& session) {
    session_.reset();
    bindContext(session_, session);
    session_.bind(7, session.shell);
    session_.bind(8, session.started_at_ms);
    session_.finish();
  }

  void PaneHistoryWriter::insertCommand(const HistorySession& session, const CapturedCommand& command) {
    command_.reset();
    bindContext(command_, session);
    command_.bind(7, command.command);
    command_.bind(8, static_cast<std::int64_t>(command.truncated));
    command_.bind(9, command.directory);
    command_.bind(10, command.started.milliseconds);
    command_.bind(11, command.duration_ns);
    if (command.exit_code) {
      command_.bind(12, *command.exit_code);
    } else {
      command_.bindNull(12);
    }

    command_.bind(13, static_cast<std::int64_t>(command.status));
    command_.bind(14, static_cast<std::int64_t>(command.author));
    command_.finish();
    if (!command.output.empty() || command.output_observed != 0) {
      output_.reset();
      output_.bind(1, std::string_view{reinterpret_cast<const char*>(command.output.data()), command.output.size()});
      output_.bind(2, static_cast<std::int64_t>(command.outputTruncated()));
      output_.bind(3, static_cast<std::int64_t>(std::min<std::uint64_t>(command.output_observed, std::numeric_limits<std::int64_t>::max())));
      output_.finish();
    }
  }

  void PaneHistoryWriter::bindContext(Statement& statement, const HistorySession& session) {
    if (session.pane > std::numeric_limits<std::int64_t>::max() || session.location.workspace.id > std::numeric_limits<std::int64_t>::max() || session.location.tab_id > std::numeric_limits<std::int64_t>::max()) {
      throw RequestError{FailureCode::resource_limit, "History identity exceeds the database integer range"};
    }

    statement.bind(1, std::span{session.id});
    statement.bind(2, static_cast<std::int64_t>(session.pane));
    statement.bind(3, static_cast<std::int64_t>(session.location.workspace.kind));
    statement.bind(4, static_cast<std::int64_t>(session.location.workspace.id));
    statement.bind(5, static_cast<std::int64_t>(session.location.tab_id));
    statement.bind(6, session.workspace_path);
  }

  HistoryRows::HistoryRows(ConcurrentMemory& memory)
      : text_(memory, max_payload_size),
        entries_(memory) {
    text_.reserve(max_payload_size);
    entries_.reserve(maximum_entries);
    clear();
  }

  void HistoryRows::clear() noexcept {
    text_.clear();
    entries_.clear();
    encoded_bytes_ = result_header_bytes;
  }

  bool HistoryRows::append(const Statement& row) {
    const auto stored = view(row);
    const auto bytes = ValueCodec<HistoryEntry>::encodedSize(stored);
    if (entries_.size() == maximum_entries || bytes > max_payload_size - encoded_bytes_) {
      return false;
    }

    // The kept entry starts with no text and views only the copies these rows hold.
    auto entry = header(row);

    entry.command = copy(stored.command);
    entry.cwd = copy(stored.cwd);
    entry.workspace_path = copy(stored.workspace_path);
    entry.provider = copy(stored.provider);
    entries_.push(entry);
    encoded_bytes_ += bytes;
    return true;
  }

  std::string_view HistoryRows::copy(std::string_view text) const {
    const auto offset = text_.size();

    text_.append(std::span{reinterpret_cast<const Byte*>(text.data()), text.size()});
    return {reinterpret_cast<const char*>(text_.readable().data() + offset), text.size()};
  }

  std::span<const HistoryEntry> HistoryRows::entries() const noexcept {
    return entries_;
  }

  HistoryEntry HistoryRows::view(const Statement& row) {
    auto entry = header(row);

    entry.provider = row.text(11);
    entry.command = row.text(6);
    entry.cwd = row.text(7);
    entry.workspace_path = row.text(8);
    return entry;
  }

  tbc::val_static<HistoryEntry> HistoryRows::header(const Statement& row) {
    if (row.integer(0) <= 0 || row.integer(1) <= 0) {
      throw RequestError{FailureCode::internal, "Invalid stored history identity"};
    }

    if (row.integer(5) < 0 || row.integer(5) > static_cast<std::int64_t>(HistoryStatus::running) || row.integer(9) < 0 || row.integer(9) > static_cast<std::int64_t>(HistoryAuthor::agent) || row.integer(10) < 0 || row.integer(10) > static_cast<std::int64_t>(HistoryOrigin::plugin)) {
      throw RequestError{FailureCode::internal, "Invalid stored history state"};
    }

    return HistoryEntry{
        .id = static_cast<std::uint64_t>(row.integer(0)),
        .pane_id = static_cast<std::uint64_t>(row.integer(1)),
        .started_at_ms = row.integer(2),
        .duration_ns = row.integer(3),
        .exit_code = row.isNull(4) ? ds::none : ds::Option{static_cast<std::int32_t>(row.integer(4))},
        .status = static_cast<HistoryStatus>(row.integer(5)),
        .author = static_cast<HistoryAuthor>(row.integer(9)),
        .origin = static_cast<HistoryOrigin>(row.integer(10)),
        .command_truncated = row.integer(12) != 0,
    };
  }

  void migrateHistory(Database& database) {
    database.execute(history_schema);

    struct Migration {
      const char* table;
      const char* column;
      const char* sql;
    };

    constexpr ds::Array migrations{
        Migration{.table = "session", .column = "tab_id", .sql = "ALTER TABLE session ADD COLUMN tab_id INTEGER NOT NULL DEFAULT 0"},
        Migration{.table = "command", .column = "tab_id", .sql = "ALTER TABLE command ADD COLUMN tab_id INTEGER NOT NULL DEFAULT 0"},
        Migration{.table = "session", .column = "title", .sql = "ALTER TABLE session ADD COLUMN title TEXT"},
        Migration{.table = "session", .column = "title_source", .sql = "ALTER TABLE session ADD COLUMN title_source INTEGER"},
        Migration{.table = "session", .column = "title_state", .sql = "ALTER TABLE session ADD COLUMN title_state INTEGER"},
        Migration{.table = "command", .column = "author", .sql = "ALTER TABLE command ADD COLUMN author INTEGER NOT NULL DEFAULT 0"},
        Migration{.table = "command", .column = "origin", .sql = "ALTER TABLE command ADD COLUMN origin INTEGER NOT NULL DEFAULT 0"},
        Migration{.table = "command", .column = "provider", .sql = "ALTER TABLE command ADD COLUMN provider TEXT"},
        Migration{.table = "command", .column = "tool_call_id", .sql = "ALTER TABLE command ADD COLUMN tool_call_id TEXT"},
    };

    for (const auto& migration : migrations) {
      Statement columns{database, "SELECT 1 FROM pragma_table_info(?1) WHERE name = ?2"};

      columns.bind(1, std::string_view{migration.table});
      columns.bind(2, std::string_view{migration.column});
      if (!columns.next()) {
        database.execute(migration.sql);
      }
    }

    database.execute("CREATE UNIQUE INDEX IF NOT EXISTS command_tool_call ON command(session_id, tool_call_id) WHERE tool_call_id IS NOT NULL; UPDATE history_schema SET version = 5 WHERE version < 5;");
  }

  bool enableHistoryIndex(Database& database) {
    bool exists = false;

    {
      Statement table{database, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'command_fts'"};

      exists = table.next();
    }

    if (!exists) {
      if (!database.tryExecute("CREATE VIRTUAL TABLE command_fts USING fts5(command, content='command', content_rowid='id', tokenize='trigram case_sensitive 0')")) {
        return false;
      }

      if (!database.tryExecute("INSERT INTO command_fts(command_fts) VALUES('rebuild')")) {
        database.tryExecute("DROP TABLE command_fts");
        return false;
      }
    }

    return database.tryExecute(R"sql(
CREATE TRIGGER IF NOT EXISTS command_fts_insert AFTER INSERT ON command BEGIN
  INSERT INTO command_fts(rowid, command) VALUES (new.id, new.command);
END;
CREATE TRIGGER IF NOT EXISTS command_fts_delete AFTER DELETE ON command BEGIN
  INSERT INTO command_fts(command_fts, rowid, command) VALUES ('delete', old.id, old.command);
END;
CREATE TRIGGER IF NOT EXISTS command_fts_update AFTER UPDATE OF command ON command BEGIN
  INSERT INTO command_fts(command_fts, rowid, command) VALUES ('delete', old.id, old.command);
  INSERT INTO command_fts(rowid, command) VALUES (new.id, new.command);
END;
)sql");
  }

  HistoryStore::HistoryStore(ConcurrentMemory& memory, const char* path, const HistoryFilters& filters)
      : memory_(memory),
        filters_(filters),
        database_(path),
        rows_(memory) {
    migrateHistory(database_);
    indexed_ = enableHistoryIndex(database_);
  }

  void HistoryStore::reportAgentCommand(const ReportAgentCommand& request, const RequestContext& context, EncodedReply<ConcurrentMemory>& reply) {
    if (!filters_.allowsAgent(request.command, request.cwd)) {
      reply.send(RequestCompleted{.request_id = request.request_id});
      return;
    }

    if (!agent_commands_) {
      agent_commands_.emplace(database_);
    }

    agent_commands_.getMut().persist(request, context);
    reply.send(RequestCompleted{.request_id = request.request_id});
  }

  void HistoryStore::record(const HistoryEventView& event) {
    if (!accepts(event)) {
      return;
    }

    if (event.kind == HistoryEventKind::launch_failed) {
      if (!launch_writer_) {
        launch_writer_.emplace(database_);
      }

      launch_writer_.getMut().persist(event);
      return;
    }

    if (!pane_writer_) {
      pane_writer_.emplace(database_);
    }

    pane_writer_.getMut().persist(event);
  }

  bool HistoryStore::accepts(const HistoryEventView& event) const noexcept {
    return event.kind != HistoryEventKind::command_finished || filters_.allowsPane(event.command.command, event.command.directory);
  }

  void HistoryStore::importEntries(const ImportHistory& request, EncodedReply<ConcurrentMemory>& reply) {
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

  void HistoryStore::query(QueryHistory request, EncodedReply<ConcurrentMemory>& reply) {
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

    sql.append(entry_columns);
    sql.append(" FROM command WHERE id <= ?1");
    if (request.entry_id != 0) {
      sql.append(" AND id = ?2");
    }

    appendMatch(sql, request.query);
    appendFilters(sql, request);
    // A distinct page counts its offset in commands, not rows: SQL cannot cut it, so the rows
    // stream newest first and stop once the page and one more command are found.
    const bool distinct = request.distinct && request.entry_id == 0;

    sql.append(distinct ? " ORDER BY started_at_ms DESC, id DESC" : " ORDER BY started_at_ms DESC, id DESC LIMIT ?7 OFFSET ?8");
    Statement statement{database_, sql};

    statement.bind(1, integer(request.snapshot_id));
    if (request.entry_id != 0) {
      statement.bind(2, integer(request.entry_id));
    }

    bindMatch(statement, request.query);
    bindFilters(statement, request);
    if (!distinct) {
      statement.bind(7, static_cast<std::int64_t>(request.limit) + 1);
      statement.bind(8, request.offset);
    }

    HashSet seen{memory_};
    std::uint32_t skipped = 0;
    bool more = false;

    while (statement.next()) {
      if (distinct) {
        if (!seen.insert(ImportIdentity::hash(command_hash_seed, statement.text(6)), true)) {
          continue;
        }

        if (skipped < request.offset) {
          ++skipped;
          continue;
        }
      }

      if (rows_.entries().size() == request.limit || !rows_.append(statement)) {
        more = true;
        break;
      }
    }

    reply.send(HistoryResults{.request_id = request.request_id, .snapshot_id = request.snapshot_id, .has_more = more, .entries = rows_.entries()});
  }

  void HistoryStore::remove(const DeleteHistory& request, EncodedReply<ConcurrentMemory>& reply) {
    Statement statement{database_, "DELETE FROM command WHERE id = ?1"};

    statement.bind(1, integer(request.id));
    statement.finish();
    reply.send(HistoryPruned{.request_id = request.request_id, .removed = static_cast<std::uint64_t>(sqlite3_changes64(database_.handle()))});
  }

  void HistoryStore::prune(const PruneHistory& request, EncodedReply<ConcurrentMemory>& reply) {
    auto sql = string("DELETE FROM command WHERE 1=1");

    appendMatch(sql, request.match);
    if (request.failed_only) {
      sql.append(" AND exit_code IS NOT NULL AND exit_code <> 0");
    }

    if (request.before_ms != 0) {
      sql.append(" AND started_at_ms < ?4");
    }

    appendScope(sql, request.scope);
    Statement statement{database_, sql};

    bindMatch(statement, request.match);
    if (request.before_ms != 0) {
      statement.bind(4, request.before_ms);
    }

    bindScope(statement, request.scope, request.scope_value);
    statement.finish();
    reply.send(HistoryPruned{.request_id = request.request_id, .removed = static_cast<std::uint64_t>(sqlite3_changes64(database_.handle()))});
  }

  void HistoryStore::readOutput(const ReadHistoryOutput& request, EncodedReply<ConcurrentMemory>& reply) {
    Statement statement{database_, "SELECT content, truncated, observed_bytes FROM command_output WHERE command_id = ?1"};

    statement.bind(1, integer(request.id));
    HistoryOutput result{.request_id = request.request_id, .id = request.id};

    if (statement.next()) {
      const auto text = statement.text(0);

      result.content = std::span{reinterpret_cast<const Byte*>(text.data()), text.size()};
      result.truncated = statement.integer(1) != 0;
      result.observed_bytes = static_cast<std::uint64_t>(statement.integer(2));
    }

    reply.send(result);
  }

  void HistoryStore::stats(const HistoryStatsQuery& request, EncodedReply<ConcurrentMemory>& reply) {
    rows_.clear();
    auto filters = string(" WHERE 1=1");

    appendScope(filters, request.scope);
    if (request.since_ms != 0) {
      filters.append(" AND started_at_ms >= ?1");
    }

    auto sql = string("SELECT COUNT(*), COUNT(DISTINCT command) FROM command");

    sql.append(filters);
    Statement totals{database_, sql};

    bindScope(totals, request.scope, request.scope_value);
    if (request.since_ms != 0) {
      totals.bind(1, request.since_ms);
    }

    checkRow(totals);
    HistoryStatsResult result{.request_id = request.request_id, .total = static_cast<std::uint64_t>(totals.integer(0)), .unique = static_cast<std::uint64_t>(totals.integer(1))};

    sql.assign("SELECT command, COUNT(*) AS n FROM command");
    sql.append(filters);
    sql.append(" GROUP BY command ORDER BY n DESC LIMIT 400");
    Statement top{database_, sql};

    bindScope(top, request.scope, request.scope_value);
    if (request.since_ms != 0) {
      top.bind(1, request.since_ms);
    }

    ds::Array<HistoryStatsEntry, maximum_stats_candidates> groups;
    std::size_t count = 0;

    while (top.next()) {
      const auto group = historyGroup(top.text(0));
      const auto occurrences = static_cast<std::uint64_t>(top.integer(1));
      const auto existing = groups.viewMut().first(count);
      auto found = std::ranges::find(existing, group, &HistoryStatsEntry::command);
      if (found != existing.end()) {
        found->count += occurrences;
      } else {
        groups.atMut(count++) = HistoryStatsEntry{.count = occurrences, .command = rows_.copy(group)};
      }
    }

    std::sort(groups.dataMut(), groups.dataMut() + count, [](const auto& left, const auto& right) {
      return left.count == right.count ? left.command < right.command : left.count > right.count;
    });

    result.top = std::span{groups}.first(std::min(count, maximum_stats_results));
    reply.send(result);
  }

  void HistoryStore::queryFuzzy(const QueryHistory& request, EncodedReply<ConcurrentMemory>& reply) {
    // The newest candidates, newest first: SQLite stops at the limit through the started_at
    // index instead of every command being read and scored on each keystroke.
    auto sql = string("SELECT id, command FROM command WHERE id <= ?1");

    appendFilters(sql, request);
    sql.append(" ORDER BY started_at_ms DESC, id DESC LIMIT ");
    sql.append(fuzzy_candidate_limit);

    Statement statement{database_, sql};

    statement.bind(1, integer(request.snapshot_id));
    bindFilters(statement, request);
    ds::Vec<RankedEntry, ConcurrentMemory> ranked{memory_};

    ranked.reserve(maximum_fuzzy_candidates);
    HashSet seen{memory_};

    ds::Vec<FuzzyCandidate, ConcurrentMemory> candidates{memory_};

    candidates.reserve(maximum_fuzzy_candidates);
    while (statement.next()) {
      FuzzyCandidate candidate{.id = statement.integer(0)};
      const auto command = statement.text(1);

      if (request.distinct) {
        candidate.command_hash = ImportIdentity::hash(command_hash_seed, command);
      }

      candidate.score = historyScore(command, request.query);
      candidates.push(candidate);
    }

    std::uint32_t order = 0;

    for (const auto& candidate : candidates) {
      if (request.distinct && !seen.insert(candidate.command_hash, true)) {
        continue;
      }

      if (candidate.score) {
        ranked.push(RankedEntry{.id = candidate.id, .score = *candidate.score, .order = order++});
      }
    }

    const auto precedes = [](const RankedEntry& left, const RankedEntry& right) {
      return left.score == right.score ? left.order < right.order : left.score > right.score;
    };

    const auto end = std::min(std::uint64_t{request.offset} + request.limit, static_cast<std::uint64_t>(ranked.size()));

    std::partial_sort(ranked.dataMut(), ranked.dataMut() + end, ranked.dataMut() + ranked.size(), precedes);
    sql.assign("SELECT ");
    sql.append(entry_columns);
    sql.append(" FROM command WHERE id = ?1");
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

    reply.send(HistoryResults{.request_id = request.request_id, .snapshot_id = request.snapshot_id, .has_more = start + rows_.entries().size() < ranked.size(), .entries = rows_.entries()});
  }

  ds::String<ConcurrentMemory> HistoryStore::string(std::string_view value) const {
    return ds::String<ConcurrentMemory>{memory_, value};
  }

  std::int64_t HistoryStore::integer(std::uint64_t value) {
    if (value > static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) {
      throw RequestError{FailureCode::invalid_request, "History identity exceeds the database integer range"};
    }

    return static_cast<std::int64_t>(value);
  }

  void HistoryStore::checkRow(Statement& statement) {
    if (!statement.next()) {
      throw RequestError{FailureCode::internal, "Expected history row is absent"};
    }
  }

  bool HistoryStore::useIndex(std::string_view query) const noexcept {
    std::size_t characters = 0;

    for (const unsigned char byte : query) {
      characters += static_cast<std::size_t>((byte & 0xc0) != 0x80);
    }

    return indexed_ && characters >= 3;
  }

  void HistoryStore::appendMatch(ds::String<ConcurrentMemory>& sql, std::string_view query) const {
    if (!query.empty()) {
      sql.append(useIndex(query) ? " AND id IN (SELECT rowid FROM command_fts WHERE command_fts MATCH ?3)" : " AND instr(lower(command), lower(?3)) > 0");
    }
  }

  void HistoryStore::bindMatch(Statement& statement, std::string_view query) const {
    if (query.empty()) {
      return;
    }

    if (!useIndex(query)) {
      statement.bind(3, query);
      return;
    }

    auto quoted = string("\"");

    for (const char byte : query) {
      quoted.push(byte);
      if (byte == '"') {
        quoted.push('"');
      }
    }

    quoted.push('"');
    statement.bind(3, std::string_view{quoted});
  }

  void HistoryStore::appendScope(ds::String<ConcurrentMemory>& sql, HistoryScope scope) {
    switch (scope) {
    case HistoryScope::global:
      break;
    case HistoryScope::cwd:
      sql.append(" AND cwd = ?6");
      break;
    case HistoryScope::workspace:
      sql.append(" AND workspace_path = ?6");
      break;
    case HistoryScope::pane:
      sql.append(" AND pane_id = ?6");
      break;
    }
  }

  void HistoryStore::bindScope(Statement& statement, HistoryScope scope, const HistoryScopeValue& value) {
    if (scope == HistoryScope::pane) {
      statement.bind(6, integer(std::get<std::uint64_t>(value)));
    } else if (scope != HistoryScope::global) {
      statement.bind(6, std::get<std::string_view>(value));
    }
  }

  void HistoryStore::appendFilters(ds::String<ConcurrentMemory>& sql, const QueryHistory& request) {
    if (request.failed_only) {
      sql.append(" AND exit_code IS NOT NULL AND exit_code <> 0");
    }

    if (request.author != HistoryAuthorFilter::all) {
      sql.append(" AND author = ?5");
    }

    appendScope(sql, request.scope);
  }

  void HistoryStore::bindFilters(Statement& statement, const QueryHistory& request) {
    if (request.author != HistoryAuthorFilter::all) {
      statement.bind(5, static_cast<std::int64_t>(request.author == HistoryAuthorFilter::agent));
    }

    bindScope(statement, request.scope, request.scope_value);
  }

}
