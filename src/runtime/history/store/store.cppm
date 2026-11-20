export module telar.runtime.history.store;

import std;
import telar.native.sqlite;
import telar.tbc;

import telar.runtime.workers.background_executor;

import telar.runtime.history.event;

import telar.base.memory.allocators;
import telar.base.memory.containers;

import telar.runtime.transport.connection;

import telar.config.runtime;
import telar.wire.vocabulary;
import telar.wire.agents;
import telar.wire.history;
import telar.platform.primitives;
import telar.runtime.history.command;
import telar.base.text;
import telar.base.ds;

// Interface: history/database.cppm
export {
  namespace telar::runtime {

    void checkSqlite(int result);

    enum class DatabaseAccess : std::uint8_t {
      private_history,
      read_only,
    };

    class Database {
    public:
      explicit Database(const char* path, DatabaseAccess access = DatabaseAccess::private_history);
      ~Database();
      Database(const Database&) = delete;
      Database& operator=(const Database&) = delete;
      Database(Database&&) = delete;
      Database& operator=(Database&&) = delete;

      void execute(const char* sql);
      bool tryExecute(const char* sql) noexcept;

      [[nodiscard]] sqlite3* handle() const noexcept;

    private:
      sqlite3* database_ = nullptr;
    };

    class Statement {
    public:
      // A prepared statement must be finalized before its database closes.
      explicit Statement(tbc::mut_a<Database> database, std::string_view sql);
      ~Statement();
      Statement(const Statement&) = delete;
      Statement& operator=(const Statement&) = delete;
      Statement(Statement&&) = delete;
      Statement& operator=(Statement&&) = delete;

      void bind(int index, std::int64_t value);
      void bind(int index, std::string_view value);
      void bind(int index, std::span<const Byte> value);
      void bindNull(int index);
      bool next();
      void finish();
      void reset();
      [[nodiscard]] std::int64_t integer(int column) const noexcept;
      [[nodiscard]] std::string_view text(int column) const;
      [[nodiscard]] bool isNull(int column) const noexcept;

    private:
      tbc::val_a<sqlite3_stmt*> statement_ = nullptr;
    };

    class Transaction {
    public:
      explicit Transaction(Database& database);
      ~Transaction();
      Transaction(const Transaction&) = delete;
      Transaction& operator=(const Transaction&) = delete;
      Transaction(Transaction&&) = delete;
      Transaction& operator=(Transaction&&) = delete;

      void commit();

    private:
      Database& database_;
      bool committed_ = false;
    };

  }
}

// Interface: history/agent_command.cppm
export {
  namespace telar::runtime {

    class AgentCommandWriter {
    public:
      explicit AgentCommandWriter(Database& database);

      void persist(const ReportAgentCommand& request, const RequestContext& context);

    private:
      static constexpr std::string_view session_sql = R"sql(
INSERT OR IGNORE INTO session (
  id, pane_id, location_kind, location_id, tab_id, workspace_path, shell, started_at_ms
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, '', ?7)
)sql";

      static constexpr std::string_view finish_sql = R"sql(
UPDATE command
SET command = ?1,
    cwd = ?2,
    duration_ns = CAST(MIN(9223372036854, MAX(0, ?3 - started_at_ms)) AS INTEGER) * 1000000,
    exit_code = ?4,
    status = 0,
    workspace_path = ?7,
    provider = ?8
WHERE session_id = ?5 AND tool_call_id = ?6
)sql";

      static constexpr std::string_view insert_sql = R"sql(
INSERT INTO command (
  session_id, pane_id, location_kind, location_id, tab_id, sequence,
  command, cwd, workspace_path, started_at_ms, duration_ns,
  exit_code, status, author, origin, provider, tool_call_id
) VALUES (
  ?1, ?2, ?3, ?4, ?5,
  (SELECT COALESCE(MAX(sequence), 0) + 1 FROM command WHERE session_id = ?1),
  ?6, ?7, ?8, ?9, 0, ?10, ?11, 1, 1, ?12, ?13
)
ON CONFLICT(session_id, tool_call_id) WHERE tool_call_id IS NOT NULL DO NOTHING
)sql";

      Database& database_;
      Statement session_;
      Statement finish_;
      Statement insert_;
    };

  }
}

// Interface: history/import_identity.cppm
export {
  namespace telar::runtime {

    class ImportIdentity {
    public:
      explicit ImportIdentity(std::string_view source) noexcept;

      // These identifiers must match existing imports, including the pinned Wyhash variant.
      static std::uint64_t hash(std::uint64_t seed, std::string_view input) noexcept;

      ds::Array<std::uint8_t, history_session_bytes> session{};
      std::uint64_t pane = 0;
    };

  }
}

// Interface: history/launch_writer.cppm
export {
  namespace telar::runtime {

    class LaunchHistoryWriter {
    public:
      explicit LaunchHistoryWriter(Database& database);

      void persist(const HistoryEventView& event);

    private:
      static constexpr std::string_view insert_sql = R"sql(
INSERT INTO launch_attempt (
  pane_id, pane_generation, location_kind, location_id, tab_id,
  workspace_path, shell, started_at_ms, failed_at_ms, phase, cause
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
)sql";

      Statement insert_;
    };

  }
}

// Interface: history/pane_writer.cppm
export {
  namespace telar::runtime {

    class PaneHistoryWriter {
    public:
      explicit PaneHistoryWriter(Database& database);

      void persist(const HistoryEventView& event);

    private:
      void ensureSession(const HistorySession& session);
      void insertCommand(const HistorySession& session, const CapturedCommand& command);
      static void bindContext(Statement& statement, const HistorySession& session);

      static constexpr std::string_view session_sql = R"sql(
INSERT OR IGNORE INTO session (
  id, pane_id, location_kind, location_id, tab_id, workspace_path, shell, started_at_ms
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
ON CONFLICT(id) DO UPDATE SET shell = excluded.shell, started_at_ms = excluded.started_at_ms
WHERE session.shell = ''
)sql";

      static constexpr std::string_view command_sql = R"sql(
INSERT INTO command (
  session_id, pane_id, location_kind, location_id, tab_id, workspace_path,
  sequence, command, command_truncated, cwd, started_at_ms, duration_ns,
  exit_code, status, author, origin
) VALUES (
  ?1, ?2, ?3, ?4, ?5, ?6,
  (SELECT COALESCE(MAX(sequence), 0) + 1 FROM command WHERE session_id = ?1),
  ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, 0
)
)sql";

      static constexpr std::string_view output_sql = "INSERT INTO command_output (command_id, content, truncated, observed_bytes) VALUES (last_insert_rowid(), ?1, ?2, ?3)";
      static constexpr std::string_view finish_sql = "UPDATE session SET finished_at_ms = ?2 WHERE id = ?1 AND finished_at_ms IS NULL";
      static constexpr std::string_view title_sql = "UPDATE session SET title = ?2, title_source = ?3, title_state = ?4 WHERE id = ?1";

      Database& database_;
      Statement session_;
      Statement command_;
      Statement output_;
      Statement finish_;
      Statement title_;
    };

  }
}

// Interface: history/result_rows.cppm
export {
  namespace telar::runtime {

    class HistoryRows {
    public:
      explicit HistoryRows(ConcurrentMemory& memory);

      void clear() noexcept;
      bool append(const Statement& row);
      // Copies a text into these rows' arena through shared access, as bumpalo's alloc takes &self: the
      // arena never moves what it holds, so earlier copies stay valid until clear().
      std::string_view copy(std::string_view text) const;
      std::span<const HistoryEntry> entries() const noexcept;

    private:
      static HistoryEntry view(const Statement& row);
      // The row's scalar columns; the entry's texts stay empty.
      static tbc::val_static<HistoryEntry> header(const Statement& row);

      static constexpr std::size_t maximum_entries = 1000;
      static constexpr std::size_t result_header_bytes = sizeof(Byte) + (sizeof(std::uint64_t) * 2) + sizeof(std::uint16_t) + sizeof(Byte);
      // Reserved whole and bounded before each copy, so the texts the entries view never move.
      mutable ByteQueue<ConcurrentMemory> text_;
      tbc::val_self<ds::Vec<HistoryEntry, ConcurrentMemory>> entries_;
      std::size_t encoded_bytes_ = result_header_bytes;
    };

  }
}

// Interface: history/schema.cppm
export {
  namespace telar::runtime {

    inline constexpr auto history_schema = R"sql(
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS history_schema (version INTEGER NOT NULL);
INSERT INTO history_schema(version) SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM history_schema);
CREATE TABLE IF NOT EXISTS launch_attempt (
  id INTEGER PRIMARY KEY,
  pane_id INTEGER NOT NULL,
  pane_generation INTEGER NOT NULL,
  location_kind INTEGER NOT NULL,
  location_id INTEGER NOT NULL,
  tab_id INTEGER NOT NULL,
  workspace_path TEXT NOT NULL,
  shell TEXT NOT NULL,
  started_at_ms INTEGER NOT NULL,
  failed_at_ms INTEGER NOT NULL,
  phase INTEGER NOT NULL,
  cause TEXT NOT NULL,
  UNIQUE(pane_id, pane_generation)
);
CREATE TABLE IF NOT EXISTS session (
  id BLOB PRIMARY KEY,
  pane_id INTEGER NOT NULL,
  location_kind INTEGER NOT NULL,
  location_id INTEGER NOT NULL,
  tab_id INTEGER NOT NULL,
  workspace_path TEXT NOT NULL,
  shell TEXT NOT NULL,
  started_at_ms INTEGER NOT NULL,
  finished_at_ms INTEGER,
  title TEXT,
  title_source INTEGER,
  title_state INTEGER
);
CREATE TABLE IF NOT EXISTS command (
  id INTEGER PRIMARY KEY,
  session_id BLOB NOT NULL REFERENCES session(id),
  pane_id INTEGER NOT NULL,
  location_kind INTEGER NOT NULL,
  location_id INTEGER NOT NULL,
  tab_id INTEGER NOT NULL,
  sequence INTEGER NOT NULL,
  command TEXT NOT NULL,
  command_truncated INTEGER NOT NULL DEFAULT 0,
  cwd TEXT NOT NULL,
  workspace_path TEXT NOT NULL,
  started_at_ms INTEGER NOT NULL,
  duration_ns INTEGER NOT NULL,
  exit_code INTEGER,
  status INTEGER NOT NULL,
  author INTEGER NOT NULL DEFAULT 0,
  origin INTEGER NOT NULL DEFAULT 0,
  provider TEXT,
  tool_call_id TEXT,
  UNIQUE(session_id, sequence)
);
CREATE TABLE IF NOT EXISTS command_output (
  command_id INTEGER PRIMARY KEY REFERENCES command(id) ON DELETE CASCADE,
  content TEXT NOT NULL,
  truncated INTEGER NOT NULL,
  observed_bytes INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS command_started_at ON command(started_at_ms DESC);
CREATE INDEX IF NOT EXISTS command_session_started ON command(session_id, started_at_ms DESC);
CREATE INDEX IF NOT EXISTS command_cwd_started ON command(cwd, started_at_ms DESC);
CREATE INDEX IF NOT EXISTS command_workspace_started ON command(workspace_path, started_at_ms DESC);
CREATE INDEX IF NOT EXISTS command_pane_started ON command(pane_id, started_at_ms DESC);
CREATE INDEX IF NOT EXISTS command_exit_started ON command(exit_code, started_at_ms DESC);
CREATE INDEX IF NOT EXISTS session_pane_started ON session(pane_id, started_at_ms DESC);
)sql";

    void migrateHistory(Database& database);
    bool enableHistoryIndex(Database& database);

  }
}

// Interface: history/store.cppm
export {
  namespace telar::runtime {

    class HistoryStore {
    public:
      explicit HistoryStore(ConcurrentMemory& memory, const char* path, const HistoryFilters& filters = defaultHistoryFilters());

      void reportAgentCommand(const ReportAgentCommand& request, const RequestContext& context, EncodedReply<ConcurrentMemory>& reply);
      void record(const HistoryEventView& event);
      bool accepts(const HistoryEventView& event) const noexcept;
      void importEntries(const ImportHistory& request, EncodedReply<ConcurrentMemory>& reply);
      void query(QueryHistory request, EncodedReply<ConcurrentMemory>& reply);
      void remove(const DeleteHistory& request, EncodedReply<ConcurrentMemory>& reply);
      void prune(const PruneHistory& request, EncodedReply<ConcurrentMemory>& reply);
      void readOutput(const ReadHistoryOutput& request, EncodedReply<ConcurrentMemory>& reply);
      void stats(const HistoryStatsQuery& request, EncodedReply<ConcurrentMemory>& reply);

    private:
      static constexpr auto entry_columns = "id, pane_id, started_at_ms, duration_ns, exit_code, status, command, cwd, workspace_path, author, origin, provider, command_truncated";
      static constexpr std::uint64_t command_hash_seed = 0x74656c6172;
      static constexpr std::size_t maximum_fuzzy_candidates = 10'000;
      static constexpr std::string_view fuzzy_candidate_limit = "10000";
      // The SQL spells the cap out, so both must name the same number.
      static_assert(unsignedNumber<std::size_t>(fuzzy_candidate_limit).value_or(0) == maximum_fuzzy_candidates);
      static constexpr std::size_t maximum_stats_candidates = 400;
      static constexpr std::size_t maximum_stats_results = 10;
      // A set: each command hash maps to nothing.
      using HashSet = ds::Map<std::uint64_t, bool, ConcurrentMemory>;

      struct RankedEntry {
        std::int64_t id;
        std::uint32_t score;
        std::uint32_t order;
      };

      struct FuzzyCandidate {
        std::int64_t id;
        std::uint64_t command_hash = 0;
        ds::Option<std::uint32_t> score;
      };

      void queryFuzzy(const QueryHistory& request, EncodedReply<ConcurrentMemory>& reply);
      ds::String<ConcurrentMemory> string(std::string_view value) const;
      static std::int64_t integer(std::uint64_t value);
      static void checkRow(Statement& statement);
      bool useIndex(std::string_view query) const noexcept;
      void appendMatch(ds::String<ConcurrentMemory>& sql, std::string_view query) const;
      void bindMatch(Statement& statement, std::string_view query) const;
      static void appendScope(ds::String<ConcurrentMemory>& sql, HistoryScope scope);
      static void bindScope(Statement& statement, HistoryScope scope, const HistoryScopeValue& value);
      static void appendFilters(ds::String<ConcurrentMemory>& sql, const QueryHistory& request);
      static void bindFilters(Statement& statement, const QueryHistory& request);

      ConcurrentMemory& memory_;
      const HistoryFilters& filters_;
      Database database_;
      HistoryRows rows_;
      bool indexed_ = false;
      ds::Option<AgentCommandWriter> agent_commands_;
      ds::Option<PaneHistoryWriter> pane_writer_;
      ds::Option<LaunchHistoryWriter> launch_writer_;
    };

  }
}
