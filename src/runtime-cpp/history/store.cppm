module;
#include "telar_platform/trace_macro.hpp"
#include "tbc/view.hpp"
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <new>

#include <sqlite3.h>

#include <cstdint>
#include <cstring>
#include <sys/types.h>
#include <unistd.h>



#include <cassert>


export module telar.runtime.history.store;

import std;

export import telar.client;


export import telar.runtime.runtime.background_executor;

export import telar.base.diagnostics;


export import telar.runtime.history.event;


export import telar.base.memory;


export import telar.runtime.transport.connection;


export import telar.base.history;
export import telar.config;
import telar.client.protocol;
import telar.platform.primitives;

// Interface: history/database.cppm
export {
namespace telar::runtime {

void checkSqlite(int result);

enum class DatabaseAccess {
  private_history,
  read_only
};

class Database {
public:
  explicit Database(const char *path, DatabaseAccess access = DatabaseAccess::private_history);
  ~Database();
  Database(const Database &) = delete;
  Database &operator=(const Database &) = delete;

  void execute(const char *sql);
  bool tryExecute(const char *sql) noexcept;

  inline sqlite3 *handle() const noexcept {
    return database_;
  }

private:
  sqlite3 *database_ = nullptr;
};

class Statement {
public:
  // A prepared statement must be finalized before its database closes.
  explicit Statement(tbc::view<Database &, tbc::lt::a> database, std::string_view sql);
  ~Statement();
  Statement(const Statement &) = delete;
  Statement &operator=(const Statement &) = delete;

  void bind(int index, std::int64_t value);
  void bind(int index, std::string_view value);
  void bind(int index, std::span<const Byte> value);
  void bindNull(int index);
  bool next();
  void finish();
  void reset();
  std::int64_t integer(int column) const noexcept;
  std::string_view text(int column) const;
  bool isNull(int column) const noexcept;

private:
  tbc::view<sqlite3_stmt *, tbc::lt::a> statement_ = nullptr;
};

class Transaction {
public:
  inline explicit Transaction(Database &database)
      : database_(database) {
    database_.execute("BEGIN IMMEDIATE");
  }

  inline ~Transaction() {
    if (!committed_) {
      database_.tryExecute("ROLLBACK");
    }
  }

  inline void commit() {
    database_.execute("COMMIT");
    committed_ = true;
  }

private:
  Database &database_;
  bool committed_ = false;
};

}
}

// Interface: history/agent_command.cppm
export {
namespace telar::runtime {

class AgentCommandWriter {
public:
  inline explicit AgentCommandWriter(Database &database)
      : database_(database),
        session_(database, session_sql),
        finish_(database, finish_sql),
        insert_(database, insert_sql) {}

  inline void persist(const ReportAgentCommand &request, const RequestContext &context) {
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

  Database &database_;
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
  inline explicit ImportIdentity(std::string_view source) noexcept {
    constexpr std::uint64_t import_seed = 0x74656c6172696d70;
    const auto low = hash(import_seed, source);
    const auto high = hash(low, source);
    static_assert(std::endian::native == std::endian::little);
    std::memcpy(session.data(), &low, sizeof(low));
    std::memcpy(session.data() + sizeof(low), &high, sizeof(high));
    pane = (low & ((std::uint64_t{1} << 62) - 1)) | 1;
  }

  // These identifiers must match existing imports, including the pinned Wyhash variant.
  inline static std::uint64_t hash(std::uint64_t seed, std::string_view input) noexcept {
    constexpr std::array<std::uint64_t, 4> secret{0xa0761d6478bd642f, 0xe7037ed1a0b428db, 0x8ebc6af09c88c6e3, 0x589965cc75374cc3};
    std::array<std::uint64_t, 3> state;
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
            state[lane] = mix(read<std::uint64_t>(input.data() + offset + 16 * lane) ^ secret[lane + 1], read<std::uint64_t>(input.data() + offset + 16 * lane + 8) ^ state[lane]);
          }
          offset += 48;
        }
        state[0] ^= state[1] ^ state[2];
      }

      while (offset + 16 < input.size()) {
        state[0] = mix(read<std::uint64_t>(input.data() + offset) ^ secret[1], read<std::uint64_t>(input.data() + offset + 8) ^ state[0]);
        offset += 16;
      }
      left = read<std::uint64_t>(input.data() + input.size() - 16);
      right = read<std::uint64_t>(input.data() + input.size() - 8);
    }

    const __uint128_t product = static_cast<__uint128_t>(left ^ secret[1]) * (right ^ state[0]);
    return mix(static_cast<std::uint64_t>(product) ^ secret[0] ^ input.size(), static_cast<std::uint64_t>(product >> 64) ^ secret[1]);
  }

  std::array<std::uint8_t, 16> session{};
  std::uint64_t pane = 0;

private:
  template <typename Integer>
  inline static std::uint64_t read(const char *bytes) noexcept {
    Integer value;
    std::memcpy(&value, bytes, sizeof(value));
    return value;
  }

  inline static std::uint64_t mix(std::uint64_t left, std::uint64_t right) noexcept {
    const __uint128_t product = static_cast<__uint128_t>(left) * right;
    return static_cast<std::uint64_t>(product) ^ static_cast<std::uint64_t>(product >> 64);
  }
};

}
}

// Interface: history/launch_writer.cppm
export {
namespace telar::runtime {

class LaunchHistoryWriter {
public:
  inline explicit LaunchHistoryWriter(Database &database)
      : insert_(database, insert_sql) {}

  inline void persist(const HistoryEventView &event) {
    TELAR_TRACE("history.persistLaunchFailure");
    const auto &session = event.session;
    const auto &failure = event.failure;
    if (session.pane > INT64_MAX || failure.generation > INT64_MAX || session.location.workspace.id > INT64_MAX || session.location.tab_id > INT64_MAX) {
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
  inline explicit PaneHistoryWriter(Database &database)
      : database_(database),
        session_(database, session_sql),
        command_(database, command_sql),
        output_(database, output_sql),
        finish_(database, finish_sql),
        title_(database, title_sql) {}

  inline void persist(const HistoryEventView &event) {
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

private:
  inline void ensureSession(const HistorySession &session) {
    session_.reset();
    bindContext(session_, session);
    session_.bind(7, session.shell);
    session_.bind(8, session.started_at_ms);
    session_.finish();
  }

  inline void insertCommand(const HistorySession &session, const CapturedCommand &command) {
    command_.reset();
    bindContext(command_, session);
    command_.bind(7, command.command);
    command_.bind(8, command.truncated);
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
      output_.bind(1, std::string_view{reinterpret_cast<const char *>(command.output.data()), command.output.size()});
      output_.bind(2, command.outputTruncated());
      output_.bind(3, static_cast<std::int64_t>(std::min<std::uint64_t>(command.output_observed, INT64_MAX)));
      output_.finish();
    }
  }

  inline static void bindContext(Statement &statement, const HistorySession &session) {
    if (session.pane > INT64_MAX || session.location.workspace.id > INT64_MAX || session.location.tab_id > INT64_MAX) {
      throw RequestError{FailureCode::resource_limit, "History identity exceeds the database integer range"};
    }

    statement.bind(1, std::span{session.id});
    statement.bind(2, static_cast<std::int64_t>(session.pane));
    statement.bind(3, static_cast<std::int64_t>(session.location.workspace.kind));
    statement.bind(4, static_cast<std::int64_t>(session.location.workspace.id));
    statement.bind(5, static_cast<std::int64_t>(session.location.tab_id));
    statement.bind(6, session.workspace_path);
  }

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

  Database &database_;
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

template <Allocator Memory>
class HistoryRows {
public:
  inline explicit HistoryRows(Memory &memory)
      : text_(memory, max_payload_size),
        entries_(AllocatorRef<HistoryEntry, Memory>{memory}) {
    text_.reserve(max_payload_size);
    entries_.reserve(maximum_entries);
    clear();
  }

  inline void clear() noexcept {
    text_.clear();
    entries_.clear();
    encoded_bytes_ = result_header_bytes;
  }

  inline bool append(const Statement &row) {
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
    entries_.push_back(entry);
    encoded_bytes_ += bytes;
    return true;
  }

  inline std::string_view copy(std::string_view text) {
    const auto offset = text_.size();
    text_.append(std::span{reinterpret_cast<const Byte *>(text.data()), text.size()});
    return {reinterpret_cast<const char *>(text_.readable().data() + offset), text.size()};
  }

  inline std::span<const HistoryEntry> entries() const noexcept {
    return entries_;
  }

private:
  inline static HistoryEntry view(const Statement &row) {
    auto entry = header(row);
    entry.provider = row.text(11);
    entry.command = row.text(6);
    entry.cwd = row.text(7);
    entry.workspace_path = row.text(8);
    return entry;
  }

  // The row's scalar columns; the entry's texts stay empty.
  inline static tbc::view<HistoryEntry, tbc::lt::static_storage> header(const Statement &row) {
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
        .exit_code = row.isNull(4) ? std::nullopt : std::optional{static_cast<std::int32_t>(row.integer(4))},
        .status = static_cast<HistoryStatus>(row.integer(5)),
        .author = static_cast<HistoryAuthor>(row.integer(9)),
        .origin = static_cast<HistoryOrigin>(row.integer(10)),
        .command_truncated = row.integer(12) != 0,
    };
  }

  static constexpr std::size_t maximum_entries = 1000;
  static constexpr std::size_t result_header_bytes = sizeof(Byte) + sizeof(std::uint64_t) * 2 + sizeof(std::uint16_t) + sizeof(Byte);
  // Reserved whole and bounded before each copy, so the texts the entries view never move.
  ByteQueue<Memory> text_;
  tbc::view<Vector<HistoryEntry, Memory>, tbc::lt::self> entries_;
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

inline void migrateHistory(Database &database) {
  database.execute(history_schema);

  struct Migration {
    const char *table;
    const char *column;
    const char *sql;
  };

  constexpr std::array migrations{
      Migration{"session", "tab_id", "ALTER TABLE session ADD COLUMN tab_id INTEGER NOT NULL DEFAULT 0"},
      Migration{"command", "tab_id", "ALTER TABLE command ADD COLUMN tab_id INTEGER NOT NULL DEFAULT 0"},
      Migration{"session", "title", "ALTER TABLE session ADD COLUMN title TEXT"},
      Migration{"session", "title_source", "ALTER TABLE session ADD COLUMN title_source INTEGER"},
      Migration{"session", "title_state", "ALTER TABLE session ADD COLUMN title_state INTEGER"},
      Migration{"command", "author", "ALTER TABLE command ADD COLUMN author INTEGER NOT NULL DEFAULT 0"},
      Migration{"command", "origin", "ALTER TABLE command ADD COLUMN origin INTEGER NOT NULL DEFAULT 0"},
      Migration{"command", "provider", "ALTER TABLE command ADD COLUMN provider TEXT"},
      Migration{"command", "tool_call_id", "ALTER TABLE command ADD COLUMN tool_call_id TEXT"},
  };

  for (const auto &migration : migrations) {
    Statement columns{database, "SELECT 1 FROM pragma_table_info(?1) WHERE name = ?2"};
    columns.bind(1, std::string_view{migration.table});
    columns.bind(2, std::string_view{migration.column});
    if (!columns.next()) {
      database.execute(migration.sql);
    }
  }

  database.execute("CREATE UNIQUE INDEX IF NOT EXISTS command_tool_call ON command(session_id, tool_call_id) WHERE tool_call_id IS NOT NULL; UPDATE history_schema SET version = 5 WHERE version < 5;");
}

inline bool enableHistoryIndex(Database &database) {
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

}
}

// Interface: history/store.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class HistoryStore {
public:
  inline explicit HistoryStore(Memory &memory, const char *path, const HistoryFilters &filters = default_history_filters)
      : memory_(memory),
        filters_(filters),
        database_(path),
        rows_(memory) {
    migrateHistory(database_);
    indexed_ = enableHistoryIndex(database_);
  }

  inline void reportAgentCommand(const ReportAgentCommand &request, const RequestContext &context, EncodedReply<Memory> &reply) {
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

  inline void record(const HistoryEventView &event) {
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

  inline bool accepts(const HistoryEventView &event) const noexcept {
    return event.kind != HistoryEventKind::command_finished || filters_.allowsPane(event.command.command, event.command.directory);
  }

  inline void importEntries(const ImportHistory &request, EncodedReply<Memory> &reply) {
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

  inline void query(QueryHistory request, EncodedReply<Memory> &reply) {
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

  inline void remove(const DeleteHistory &request, EncodedReply<Memory> &reply) {
    Statement statement{database_, "DELETE FROM command WHERE id = ?1"};
    statement.bind(1, integer(request.id));
    statement.finish();
    reply.send(HistoryPruned{.request_id = request.request_id,
                             .removed = static_cast<std::uint64_t>(sqlite3_changes64(database_.handle()))});
  }

  inline void prune(const PruneHistory &request, EncodedReply<Memory> &reply) {
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

  inline void readOutput(const ReadHistoryOutput &request, EncodedReply<Memory> &reply) {
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

  inline void stats(const HistoryStatsQuery &request, EncodedReply<Memory> &reply) {
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

  struct FuzzyCandidate {
    std::int64_t id;
    std::int64_t timestamp;
    std::uint64_t command_hash = 0;
    std::optional<std::uint32_t> score;
  };

  static bool newerCandidate(const FuzzyCandidate &left, const FuzzyCandidate &right) noexcept {
    return left.timestamp == right.timestamp ? left.id > right.id : left.timestamp > right.timestamp;
  }

  void queryFuzzy(const QueryHistory &request, EncodedReply<Memory> &reply) {
    auto sql = string("SELECT id, started_at_ms, command FROM command WHERE id <= ?1");
    appendFilters(sql, request);

    Statement statement{database_, sql};
    statement.bind(1, integer(request.snapshot_id));
    bindFilters(statement, request);
    Vector<RankedEntry, Memory> ranked{AllocatorRef<RankedEntry, Memory>{memory_}};
    ranked.reserve(maximum_fuzzy_candidates);
    HashSet seen{0, std::hash<std::uint64_t>{}, std::equal_to<std::uint64_t>{}, AllocatorRef<std::uint64_t, Memory>{memory_}};

    Vector<FuzzyCandidate, Memory> candidates{AllocatorRef<FuzzyCandidate, Memory>{memory_}};
    candidates.reserve(maximum_fuzzy_candidates);
    bool heap = false;
    while (statement.next()) {
      FuzzyCandidate candidate{.id = statement.integer(0), .timestamp = statement.integer(1)};
      if (candidates.size() == maximum_fuzzy_candidates) {
        if (!heap) {
          std::make_heap(candidates.begin(), candidates.end(), newerCandidate);
          heap = true;
        }

        if (!newerCandidate(candidate, candidates.front())) {
          continue;
        }
      }

      const auto command = statement.text(2);
      if (request.distinct) {
        candidate.command_hash = ImportIdentity::hash(command_hash_seed, command);
      }

      candidate.score = historyScore(command, request.query);
      if (heap) {
        std::pop_heap(candidates.begin(), candidates.end(), newerCandidate);
        candidates.back() = candidate;
        std::push_heap(candidates.begin(), candidates.end(), newerCandidate);
      } else {
        candidates.push_back(candidate);
      }
    }

    std::sort(candidates.begin(), candidates.end(), newerCandidate);
    std::uint32_t order = 0;
    for (const auto &candidate : candidates) {
      if (request.distinct && !seen.insert(candidate.command_hash).second) {
        continue;
      }

      if (candidate.score) {
        ranked.push_back(RankedEntry{candidate.id, *candidate.score, order++});
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
}
