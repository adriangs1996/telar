export module telar.runtime.history.store;

import std;
import telar.native.sqlite;
import telar.sys.posix;
import telar.tbc;

import telar.runtime.workers.background_executor;

import telar.runtime.history.event;
import telar.runtime.history.index;
import telar.runtime.history.matching;
import telar.runtime.history.directory_keys;
import telar.runtime.history.privacy;

import telar.base.memory.allocators;
import telar.base.memory.containers;

import telar.runtime.transport.connection;

import telar.config.runtime;
import telar.wire.vocabulary;
import telar.wire.agents;
import telar.wire.history;
import telar.platform.primitives;
import telar.runtime.history.command;
import telar.base.ds;

// Interface: history/database.cppm
export {
  namespace telar::runtime {

    void checkSqlite(int result);

    enum class DatabaseAccess : std::uint8_t {
      private_history,
      read_only,
    };

    // Trusted to keep the statements it hands out valid: SQLite keeps a connection's statements
    // across its other calls, and the connection finalizes a kept one only while none uses it.
    class [[tbc::shared]] Database {
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
      [[nodiscard]] std::int64_t changes() const noexcept;

      // Ends the statement that runs while `cancelled` is set, as a newer query takes its place;
      // nothing ends one while it is null.
      void interruptWhen(const std::atomic<bool>* cancelled) noexcept;

      // A statement this connection keeps prepared, by its SQL, for a read that runs again with
      // other values; `kept` is false for one prepared for this call alone, as when the kept one
      // is in use. Each is handed back with `release`.
      struct Prepared {
        sqlite3_stmt* statement = nullptr;
        bool kept = false;
      };

      [[nodiscard]] Prepared prepared(std::string_view sql);
      // Resets a kept statement and clears its values, for its next use.
      void release(sqlite3_stmt* statement) noexcept;

    private:
      // Statements whose SQL a read builds from its filters: as many shapes as a person's
      // searches and browsing ask for, the one used least lately making room for a new one.
      static constexpr std::size_t kept_statements = 24;

      struct Kept {
        std::uint64_t hash = 0;
        std::uint64_t used = 0;
        sqlite3_stmt* statement = nullptr;
        bool busy = false;
      };

      sqlite3* database_ = nullptr;
      ds::Array<Kept, kept_statements> kept_{};
      std::uint64_t kept_clock_ = 0;
    };

    // How long a statement stays prepared: for this call, or kept by its database for the next
    // call with the same SQL.
    enum class Preparation : std::uint8_t {
      once,
      kept,
    };

    class Statement {
    public:
      // A prepared statement must be finalized before its database closes; a kept one, which
      // its database finalizes, is handed back to it.
      explicit Statement(tbc::mut_a<Database> database, std::string_view sql, Preparation preparation = Preparation::once);
      ~Statement();
      Statement(const Statement&) = delete;
      Statement& operator=(const Statement&) = delete;
      Statement(Statement&&) = delete;
      Statement& operator=(Statement&&) = delete;

      void bind(int index, std::int64_t value);
      void bind(int index, std::string_view value);
      void bind(int index, std::span<const Byte> value);
      void bind(int index, ds::Option<std::int32_t> value);
      void bindNull(int index);
      bool next();
      void finish();
      void reset();
      [[nodiscard]] std::int64_t integer(int column) const noexcept;
      [[nodiscard]] std::string_view text(int column) const;
      [[nodiscard]] bool isNull(int column) const noexcept;

    private:
      tbc::val_a<sqlite3_stmt*> statement_ = nullptr;
      // The database that keeps the statement, or null for one this finalizes.
      tbc::val_a<Database*> keeper_ = nullptr;
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

    // A write that commits whole or not at all, inside a transaction already open or as one of its
    // own: a savepoint, which nests.
    class WriteScope {
    public:
      explicit WriteScope(Database& database);
      ~WriteScope();
      WriteScope(const WriteScope&) = delete;
      WriteScope& operator=(const WriteScope&) = delete;
      WriteScope(WriteScope&&) = delete;
      WriteScope& operator=(WriteScope&&) = delete;

      void commit();

    private:
      Database& database_;
      bool committed_ = false;
    };

  }
}

// Interface: history/command_texts.cppm
export {
  namespace telar::runtime {

    // Each distinct command text the history keeps once, by an id the runs refer to.
    class HistoryTexts {
    public:
      explicit HistoryTexts(Database& database);

      // The id of `text`, stored first when the history has none, in the caller's write.
      std::int64_t idOf(std::string_view text);

      // Forgets the ids it remembers, after texts were deleted.
      void forget() noexcept;

      // The hash a text is found by, the pinned Wyhash ImportIdentity uses.
      static std::int64_t hash(std::string_view text) noexcept;

    private:
      struct Remembered {
        std::int64_t hash = 0;
        std::int64_t id = 0;
      };

      static constexpr std::size_t remembered = 256;

      Statement find_;
      Statement insert_;
      ds::Array<Remembered, remembered> recent_{};
    };

    // What the writes of one transaction changed, for the index and the clients that watch, kept
    // until it commits: a write that rolls back takes its changes with it.
    class HistoryChangeLog {
    public:
      enum class Kind : std::uint8_t {
        ran,
        removed,
        removed_text,
        session,
        selected,
      };

      struct Item {
        Kind kind = Kind::ran;
        std::int64_t id = 0;
        std::uint64_t pane = 0;
        std::int64_t value = 0;
      };

      static constexpr std::size_t maximum_items = 4096;

      explicit HistoryChangeLog(ConcurrentMemory& memory);

      void ran(std::int64_t id, std::uint64_t pane);
      void removed(std::int64_t id);
      // Every run of text `text_id` went, as the deletion of entry `entry_id` asked.
      void removedText(std::int64_t text_id, std::int64_t entry_id);
      void session(std::uint64_t pane, std::int64_t started_ms);
      void selected(std::int64_t text_id);
      // Too much changed to list: the index loads again.
      void many() noexcept;

      [[nodiscard]] std::size_t mark() const noexcept;
      void rewind(std::size_t mark) noexcept;
      void clear() noexcept;
      [[nodiscard]] bool empty() const noexcept;
      [[nodiscard]] bool manyChanged() const noexcept;
      [[nodiscard]] std::span<const Item> items() const noexcept;

    private:
      void push(Item item);

      ds::Vec<Item, ConcurrentMemory> items_;
      bool many_ = false;
      std::size_t many_mark_ = 0;
    };

    // How the writers record a command: the machine to name when a run names none, whether a run
    // that failed is kept, and the directory keys.
    struct HistoryWriteOptions {
      std::string_view host;
      bool store_failed = true;
      DirectoryKeys* keys = nullptr;
      // Where the captured outputs are made plain for their index; without it they go unindexed.
      ConcurrentMemory* memory = nullptr;
    };

  }
}

// Interface: history/agent_command.cppm
export {
  namespace telar::runtime {

    class AgentCommandWriter {
    public:
      explicit AgentCommandWriter(Database& database, HistoryChangeLog* log = nullptr, HistoryWriteOptions options = {});

      void persist(const ReportAgentCommand& request, const RequestContext& context);

      void forgetTexts() noexcept;

    private:
      // A report as it is written: its directories as shown, when it came, how it ended, and
      // whether a failure the history does not keep drops it.
      struct AgentRun {
        std::string_view workspace_path;
        std::string_view cwd;
        std::int64_t now = 0;
        HistoryStatus status = HistoryStatus::completed;
        bool dropped = false;
        std::int64_t text = 0;
      };

      void openSession(const ReportAgentCommand& request, const RequestContext& context, const AgentRun& run);
      // Completes the run the call's start stored; false when there is none.
      bool finishCall(const ReportAgentCommand& request, const RequestContext& context, const AgentRun& run);
      void insertCall(const ReportAgentCommand& request, const RequestContext& context, const AgentRun& run);

      static constexpr std::string_view session_sql = R"sql(
INSERT OR IGNORE INTO session (
  id, pane_id, location_kind, location_id, tab_id, workspace_path, shell, started_at_ms
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, '', ?7)
)sql";

      static constexpr std::string_view finish_sql = R"sql(
UPDATE command
SET text_id = ?1,
    cwd = ?2,
    duration_ns = CAST(MIN(9223372036854, MAX(0, ?3 - started_at_ms)) AS INTEGER) * 1000000,
    exit_code = ?4,
    status = ?11,
    workspace_path = ?7,
    provider = ?8,
    cwd_key = ?9,
    workspace_key = ?10
WHERE session_id = ?5 AND tool_call_id = ?6
RETURNING id
)sql";

      static constexpr std::string_view insert_sql = R"sql(
INSERT INTO command (
  session_id, pane_id, location_kind, location_id, tab_id, sequence,
  text_id, cwd, workspace_path, started_at_ms, duration_ns,
  exit_code, status, author, origin, provider, tool_call_id, cwd_key, workspace_key, host
) VALUES (
  ?1, ?2, ?3, ?4, ?5,
  (SELECT COALESCE(MAX(sequence), 0) + 1 FROM command WHERE session_id = ?1),
  ?6, ?7, ?8, ?9, 0, ?10, ?11, 1, 1, ?12, ?13, ?14, ?15, ?16
)
ON CONFLICT(session_id, tool_call_id) WHERE tool_call_id IS NOT NULL DO NOTHING
RETURNING id
)sql";

      static constexpr std::string_view drop_sql = "DELETE FROM command WHERE id = ?1";

      Database& database_;
      HistoryChangeLog* log_;
      HistoryWriteOptions options_;
      HistoryTexts texts_;
      Statement session_;
      Statement finish_;
      Statement insert_;
      Statement drop_;
      FixedText<PATH_MAX> cwd_key_;
      FixedText<PATH_MAX> workspace_key_;
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
      // The sequence an imported entry takes in its source's session: what it ran and when, and
      // which run of that it is among the identical ones of its request, so the same run imported
      // again lands on the entry it already is. It is never below first_entry, where the
      // positions older imports numbered their entries by stay.
      static std::int64_t entry(std::int64_t started_at_ms, std::string_view command, std::uint32_t run = 0) noexcept;

      static constexpr std::int64_t first_entry = static_cast<std::int64_t>(std::uint64_t{1} << 62U);

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

    // A person chose a command from the history for a pane, and it counts once the pane runs
    // it unchanged in the same directory, named by its key's hash.
    struct HistoryChoice {
      std::uint64_t pane = 0;
      std::int64_t text_id = 0;
      std::int64_t cwd_hash = 0;
      std::int64_t chosen_ms = 0;
    };

    class PaneHistoryWriter {
    public:
      static constexpr std::size_t maximum_choices = 64;
      static constexpr std::int64_t choice_lifetime_ms = std::int64_t{10} * 60 * 1000;

      explicit PaneHistoryWriter(Database& database, HistoryChangeLog* log = nullptr, HistoryWriteOptions options = {});

      void persist(const HistoryEventView& event);

      // The pane's next command counts as chosen when it runs `text_id` in `cwd_key`.
      void choose(std::uint64_t pane, std::int64_t text_id, std::string_view cwd_key, std::int64_t now_ms);

      void forgetTexts() noexcept;

    private:
      void ensureSession(const HistorySession& session);
      // What the event writes, inside the write that persist opened.
      void apply(const HistoryEventView& event);
      std::int64_t insertCommand(const HistorySession& session, const CapturedCommand& command, HistoryStatus status);
      void finishCommand(const HistorySession& session, const CapturedCommand& command);
      void closeSession(const HistorySession& session, std::int64_t finished_at_ms);
      void storeOutput(std::int64_t id, const CapturedCommand& command);
      void noteChoice(std::uint64_t pane, std::int64_t text_id, std::string_view cwd_key);
      void followMove(const CapturedCommand& command);
      // OLD and NEW of a plain `mv OLD NEW`; none for any other command.
      static ds::Option<ds::Array<std::string_view, 2>> moveOperands(std::string_view text);
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
  sequence, text_id, command_truncated, cwd, started_at_ms, duration_ns,
  exit_code, status, author, origin, cwd_key, workspace_key, host, branch, shell
) VALUES (
  ?1, ?2, ?3, ?4, ?5, ?6,
  (SELECT COALESCE(MAX(sequence), 0) + 1 FROM command WHERE session_id = ?1),
  ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, 0, ?15, ?16, ?17, ?18, ?19
)
RETURNING id
)sql";

      static constexpr std::string_view running_sql = "SELECT id FROM command WHERE session_id = ?1 AND status = 2 AND started_at_ms = ?2 AND text_id = ?3 ORDER BY id DESC LIMIT 1";
      static constexpr std::string_view complete_sql = "UPDATE command SET duration_ns = ?2, exit_code = ?3, status = ?4, command_truncated = ?5 WHERE id = ?1";
      static constexpr std::string_view drop_sql = "DELETE FROM command WHERE id = ?1";
      static constexpr std::string_view output_sql = "INSERT INTO command_output (command_id, content, truncated, observed_bytes) VALUES (?4, ?1, ?2, ?3)";
      static constexpr std::string_view finish_sql = "UPDATE session SET finished_at_ms = ?2 WHERE id = ?1 AND finished_at_ms IS NULL";
      static constexpr std::string_view orphans_sql = "UPDATE command SET status = 1, duration_ns = CAST(MIN(9223372036854, MAX(0, ?2 - started_at_ms)) AS INTEGER) * 1000000 WHERE session_id = ?1 AND status = 2 RETURNING id, pane_id";
      static constexpr std::string_view title_sql = "UPDATE session SET title = ?2, title_source = ?3, title_state = ?4 WHERE id = ?1";
      static constexpr std::string_view select_sql = "UPDATE command_text SET selected = selected + 1 WHERE id = ?1";

      Database& database_;
      HistoryChangeLog* log_;
      HistoryWriteOptions options_;
      HistoryTexts texts_;
      bool output_index_ = false;
      Statement session_;
      Statement command_;
      Statement running_;
      Statement complete_;
      Statement drop_;
      Statement output_;
      Statement finish_;
      Statement orphans_;
      Statement title_;
      Statement select_;
      ds::Option<Statement> output_index_statement_;
      ds::Array<HistoryChoice, maximum_choices> choices_{};
      FixedText<PATH_MAX> cwd_key_;
      FixedText<PATH_MAX> workspace_key_;
      ds::Option<ds::String<ConcurrentMemory>> plain_;
    };

  }
}

// Interface: history/result_rows.cppm
export {
  namespace telar::runtime {

    // What a row has besides its columns: what the index knows of its command, and where the
    // query matched it.
    struct HistoryRowExtra {
      std::uint32_t run_count = 0;
      ds::Option<std::int32_t> last_exit;
      std::span<const HistoryRange> ranges;
      std::string_view excerpt;
      std::span<const HistoryRange> excerpt_ranges;
      bool neighbour = false;
    };

    // A row's columns as a query reads them, in the order entry_columns names them.
    class HistoryRows {
    public:
      explicit HistoryRows(ConcurrentMemory& memory);

      void clear() noexcept;
      bool append(const Statement& row, const HistoryRowExtra& extra = {});
      // Copies a text into these rows' arena through shared access, as bumpalo's alloc takes &self: the
      // arena never moves what it holds, so earlier copies stay valid until clear().
      std::string_view copy(std::string_view text) const;
      std::span<const HistoryEntry> entries() const noexcept;

      // The columns entry_columns names, of `command` aliased c joined to `command_text` aliased t.
      static constexpr auto entry_columns = "c.id, c.pane_id, c.started_at_ms, c.duration_ns, c.exit_code, c.status, t.text, c.cwd, c.workspace_path, c.author, c.origin, c.provider, c.command_truncated, c.host, c.branch, c.shell, c.text_id";

    private:
      static HistoryEntry view(const Statement& row);
      // The row's scalar columns; the entry's texts stay empty.
      static tbc::val_static<HistoryEntry> header(const Statement& row);
      std::span<const HistoryRange> keep(std::span<const HistoryRange> ranges);

      static constexpr std::size_t maximum_entries = 1000;
      static constexpr std::size_t result_header_bytes = sizeof(Byte) + (sizeof(std::uint64_t) * 2) + sizeof(std::uint16_t) + sizeof(Byte);

      // Reserved whole and bounded before each copy, so the texts the entries view never move.
      class [[tbc::shared]] TextArena {
      public:
        explicit TextArena(ConcurrentMemory& memory, std::size_t limit);

        void reserve(std::size_t capacity);
        void clear() noexcept;
        std::string_view copy(std::string_view text) const;

      private:
        mutable ByteQueue<ConcurrentMemory> storage_;
      };

      TextArena text_;
      tbc::val_self<ds::Vec<HistoryEntry, ConcurrentMemory>> entries_;
      // Reserved whole, as the arena, so the ranges the entries view never move.
      ds::Vec<HistoryRange, ConcurrentMemory> ranges_;
      std::size_t encoded_bytes_ = result_header_bytes;
    };

  }
}

// Interface: history/schema.cppm
export {
  namespace telar::runtime {

    // The version a history this release writes has, and what made each one:
    // 5 the directories and agent columns, 6 outputs without the integration's marks, 7 the
    // directories' keys, 8 each command text once with the runs referring to it, the machine,
    // branch and shell of each run, the captured output's index and incremental vacuum.
    inline constexpr std::int64_t history_version = 8;

    inline constexpr auto history_schema = R"sql(
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
CREATE TABLE IF NOT EXISTS command_text (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  hash INTEGER NOT NULL,
  text TEXT NOT NULL,
  selected INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS command_text_hash ON command_text(hash);
)sql";

    // The runs, which a history before version 8 keeps with their texts.
    inline constexpr auto history_runs = R"sql(
CREATE TABLE IF NOT EXISTS command (
  -- Never reused, so a listing's snapshot holds the runs it saw and no later one.
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id BLOB NOT NULL REFERENCES session(id),
  pane_id INTEGER NOT NULL,
  location_kind INTEGER NOT NULL,
  location_id INTEGER NOT NULL,
  tab_id INTEGER NOT NULL,
  sequence INTEGER NOT NULL,
  text_id INTEGER NOT NULL REFERENCES command_text(id),
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
  -- What a scope matches the directories by: cwd and workspace_path as directoryKey makes them.
  cwd_key TEXT NOT NULL DEFAULT '',
  workspace_key TEXT NOT NULL DEFAULT '',
  host TEXT NOT NULL DEFAULT '',
  branch TEXT NOT NULL DEFAULT '',
  shell TEXT NOT NULL DEFAULT '',
  UNIQUE(session_id, sequence)
);
CREATE TABLE IF NOT EXISTS command_output (
  command_id INTEGER PRIMARY KEY REFERENCES command(id) ON DELETE CASCADE,
  content TEXT NOT NULL,
  truncated INTEGER NOT NULL,
  observed_bytes INTEGER NOT NULL
);
)sql";

    // The runs' indexes, built after a migration copied the runs rather than kept up row by row.
    inline constexpr auto history_run_indexes = R"sql(
CREATE INDEX IF NOT EXISTS command_started_at ON command(started_at_ms DESC, id DESC);
CREATE INDEX IF NOT EXISTS command_session_started ON command(session_id, started_at_ms DESC);
CREATE INDEX IF NOT EXISTS command_pane_started ON command(pane_id, started_at_ms DESC, id DESC);
DROP INDEX IF EXISTS command_exit_started;
CREATE INDEX IF NOT EXISTS command_text_started ON command(text_id, started_at_ms DESC);
CREATE INDEX IF NOT EXISTS command_cwd_key_started ON command(cwd_key, started_at_ms DESC, id DESC);
CREATE INDEX IF NOT EXISTS command_workspace_key_started ON command(workspace_key, started_at_ms DESC, id DESC);
CREATE UNIQUE INDEX IF NOT EXISTS command_tool_call ON command(session_id, tool_call_id) WHERE tool_call_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS session_pane_started ON session(pane_id, started_at_ms DESC);
)sql";

    // Creates the history's tables, or brings an older history's to version 5; the versions past
    // it read and rewrite rows, which the store does when it opens. Registers the functions the
    // history's SQL calls on `database`.
    void migrateHistory(Database& database);
    bool enableHistoryIndex(Database& database);

    // A command's output as the search reads it: without the terminal's control sequences, its
    // line breaks and tabs as spaces, written to `out`.
    void plainHistoryOutput(std::string_view output, ds::String<ConcurrentMemory>& out);

  }
}

// Interface: history/index_feed.cppm
export {
  namespace telar::runtime {

    // The changes the writer committed, for the reader to apply to its index: the writer
    // publishes, the reader drains. Each change owns its texts.
    class [[tbc::shared]] HistoryIndexFeed {
    public:
      enum class Kind : std::uint8_t {
        upsert,
        remove,
        remove_text,
        session,
        select,
        reload,
      };

      // A change's texts live in one buffer it owns, so a change moves without them moving.
      struct Change {
        explicit Change(ConcurrentMemory& memory);

        // The run, its texts viewing this change's buffer.
        [[nodiscard]] HistoryRunFacts facts() const;
        void keep(const HistoryRunFacts& facts);

        Kind kind = Kind::upsert;
        HistoryRunFacts run;
        // The lengths of the text, the two keys, the host, the branch and the shell.
        static constexpr std::size_t parts = 6;

        ds::Array<std::uint32_t, parts> lengths{};
        ds::String<ConcurrentMemory> texts;
      };

      explicit HistoryIndexFeed(ConcurrentMemory& memory);

      // Each change is published once its transaction committed.
      void publish(ds::Vec<Change, ConcurrentMemory>& changes);
      // The changes published since the last drain, in order.
      void drain(ds::Vec<Change, ConcurrentMemory>& changes);

    private:
      std::mutex mutex_;
      ds::Vec<Change, ConcurrentMemory> pending_;
    };

  }
}

// Interface: history/notices.cppm
export {
  namespace telar::runtime {

    // The changes the writer committed, for the clients that watch: any thread takes them.
    class [[tbc::shared]] HistoryNotices {
    public:
      static constexpr std::size_t maximum_changes = 16;

      explicit HistoryNotices(ConcurrentMemory& memory);

      // Past a few, what changed is many things: a client refreshes once.
      void add(HistoryChange change, std::int64_t entry, std::uint64_t pane);
      // Oldest first, in place of what `out` held.
      void take(ds::Vec<HistoryChanged, ConcurrentMemory>& out);

    private:
      std::mutex mutex_;
      ds::Vec<HistoryChanged, ConcurrentMemory> changes_;
      std::uint64_t revision_ = 0;
    };

  }
}

// Interface: history/store.cppm
export {
  namespace telar::runtime {

    class HistoryStore {
    public:
      explicit HistoryStore(ConcurrentMemory& memory, const char* path, const HistoryFilters& filters = defaultHistoryFilters());
      ~HistoryStore();

      HistoryStore(const HistoryStore&) = delete;
      HistoryStore& operator=(const HistoryStore&) = delete;
      HistoryStore(HistoryStore&&) = delete;
      HistoryStore& operator=(HistoryStore&&) = delete;

      // By default one thread calls the store. Once its lanes are separated, one thread writes,
      // calling the writes, flush and maintain, and another reads, calling the reads and warm:
      // each has its own connection, and the index is the reader's. The writer then gathers the
      // events it records into one transaction, which flush commits.
      void separateLanes();

      // Writes.
      void reportAgentCommand(const ReportAgentCommand& request, const RequestContext& context, EncodedReply<ConcurrentMemory>& reply);
      void record(const HistoryEventView& event);
      bool accepts(const HistoryEventView& event) const noexcept;
      void importEntries(const ImportHistory& request, EncodedReply<ConcurrentMemory>& reply);
      void remove(const DeleteHistory& request, EncodedReply<ConcurrentMemory>& reply);
      // Every run of the command the entry ran.
      void removeCommand(const DeleteHistoryCommand& request, EncodedReply<ConcurrentMemory>& reply);
      void prune(const PruneHistory& request, EncodedReply<ConcurrentMemory>& reply);
      void choose(const ChooseHistoryEntry& request, EncodedReply<ConcurrentMemory>& reply);
      // Removes what today's filters refuse and redacts what they would keep redacted.
      void rewrite(const RewriteHistory& request, EncodedReply<ConcurrentMemory>& reply);
      // Commits the events recorded since the last flush.
      void flush();
      // Keeps the history within its retention and its file tidy; called when the writer idles.
      void maintain(std::int64_t now_ms);
      // The changes committed since the last call, for the clients that watch, oldest first, in
      // place of what `out` held. Any thread may take them.
      void takeChanges(ds::Vec<HistoryChanged, ConcurrentMemory>& out);

      // Reads.
      void query(QueryHistory request, EncodedReply<ConcurrentMemory>& reply, const std::atomic<bool>* cancelled = nullptr);
      void readOutput(const ReadHistoryOutput& request, EncodedReply<ConcurrentMemory>& reply);
      void stats(const HistoryStatsQuery& request, EncodedReply<ConcurrentMemory>& reply);
      // How one command's runs went, for the inspector: from the index once it holds every run,
      // else from SQL.
      void commandStats(const QueryHistoryCommandStats& request, EncodedReply<ConcurrentMemory>& reply);
      // The workspaces a session was recorded in, each path once.
      void workspaces(const QueryHistoryWorkspaces& request, EncodedReply<ConcurrentMemory>& reply);
      // Loads the index and applies what the writer committed; called when the reader idles.
      void warm();

      // Brings an older history to the current version, which can take a while for a large one,
      // so the store opens without it: the writer does it before its first write, and until then
      // a query on separate lanes is answered that the history is upgrading. Then it closes the
      // runs an earlier runtime left running. Once only.
      void upgrade();

      // How SQLite runs the statement the query reads it with when the index does not answer:
      // its listing, or with `output` its search of the outputs. One line of EXPLAIN QUERY PLAN
      // each, for a check and a benchmark.
      void plan(QueryHistory request, ds::String<ConcurrentMemory>& out);

      // The most a search from SQL scores: runs, or for a list of each command once, commands.
      static constexpr std::size_t maximum_fuzzy_candidates = 10'000;
      static constexpr std::size_t index_page_rows = 65'536;
      static constexpr std::size_t detail_batch = 64;

    private:
      static constexpr std::uint64_t command_hash_seed = 0x74656c6172;
      static constexpr std::size_t maximum_stats_results = 10;
      static constexpr std::size_t batch_events = 64;
      static constexpr auto batch_age = std::chrono::milliseconds{5};
      // A set: each command hash maps to nothing.
      using HashSet = ds::Map<std::uint64_t, bool, ConcurrentMemory>;

      struct RankedEntry {
        std::int64_t id;
        std::uint32_t score;
        std::uint32_t order;
      };

      // Writes.
      template <typename Write>
      void write(Write&& body);
      void beginBatch();
      void publish();
      void reap();
      void retain(std::int64_t now_ms);
      void keepNewestRuns(std::uint32_t keep);
      void checkpoint() noexcept;
      // Turns a file without incremental vacuum into one with it, once, when much of it is free.
      void convertVacuum();
      void forgetTexts() noexcept;
      PaneHistoryWriter& paneWriter();
      [[nodiscard]] HistoryWriteOptions writeOptions() noexcept;

      // Reads.
      // Whether a read may run: true once the file is current; on separate lanes before that, the
      // request is answered that the history is upgrading.
      bool readable(std::uint64_t request_id, EncodedReply<ConcurrentMemory>& reply);
      [[nodiscard]] std::unique_lock<std::mutex> readLock();
      // The reader's connection, or the one an in-memory history shares.
      static tbc::mut_a<Database> readerOf(tbc::mut_a<ds::Option<Database>> reader, tbc::mut_a<Database> writer) noexcept;
      void apply();
      // What the writer committed, from `feed` onto `index`, through `applying`.
      static void applyChanges(HistoryIndexFeed& feed, ds::Vec<HistoryIndexFeed::Change, ConcurrentMemory>& applying, HistoryIndex& index);
      bool loadIndex(std::size_t pages);
      [[nodiscard]] std::int64_t newestId();
      void queryIndex(const QueryHistory& request, const HistoryMatcher& matcher, EncodedReply<ConcurrentMemory>& reply, const std::atomic<bool>* cancelled);
      // The query as the index answers it, but for the keys of its directories.
      static tbc::val_a<HistoryIndexQuery> indexQuery(tbc::ref_a<QueryHistory> request, tbc::ref_a<HistoryMatcher> matcher, tbc::val_a<const std::atomic<bool>*> cancelled);
      static void detailSql(ds::String<ConcurrentMemory>& sql);
      void querySql(const QueryHistory& request, const HistoryMatcher& matcher, EncodedReply<ConcurrentMemory>& reply);
      // The matches of `statement`'s rows, newest first, appended to `rows`; whether there is more.
      static bool listSqlByTime(const QueryHistory& request, const HistoryMatcher& matcher, Statement& statement, HistoryRows& rows, HistoryMatchWork& scratch, ConcurrentMemory& memory);
      // The matches of `statement`'s rows with their scores; whether the cap stopped the read.
      static bool rankSql(const QueryHistory& request, const HistoryMatcher& matcher, Statement& statement, ds::Vec<RankedEntry, ConcurrentMemory>& ranked, HistoryMatchWork& scratch, ConcurrentMemory& memory);
      void queryOutput(const QueryHistory& request, EncodedReply<ConcurrentMemory>& reply);

      // A piece of an output around where the query matched it, and that match within it.
      struct Excerpt {
        std::string_view text;
        ds::Array<HistoryRange, 1> ranges{};
        std::size_t count = 0;
      };

      static tbc::val_a<Excerpt> excerptOf(const HistoryMatcher& matcher, tbc::val_a<std::string_view> plain, HistoryMatchWork& scratch);
      void statsSql(const HistoryStatsQuery& request, EncodedReply<ConcurrentMemory>& reply);
      // The id of the text a command stats request names, by a run of it or by itself.
      [[nodiscard]] ds::Option<std::int64_t> commandTextId(const QueryHistoryCommandStats& request);
      // commandStats while the index does not hold every run.
      [[nodiscard]] ds::Option<HistoryIndexCommandStats> commandStatsSql(std::int64_t text_id, std::int64_t until_ms, std::span<std::uint32_t> per_day);
      ds::String<ConcurrentMemory> string(std::string_view value) const;
      static std::int64_t integer(std::uint64_t value);
      static void checkRow(Statement& statement);
      bool useIndex(std::string_view query) const noexcept;
      static void bindPhrase(Statement& statement, std::string_view query);
      // The SQL a query reads from SQLite: its listing, or its search of the outputs.
      void sqlOf(const QueryHistory& request, ds::String<ConcurrentMemory>& sql) const;
      [[nodiscard]] static bool paged(const QueryHistory& request) noexcept;
      static void bindQuery(Statement& statement, const QueryHistory& request, bool indexed, DirectoryKeys& keys, FixedText<PATH_MAX>& key);
      static void appendScope(ds::String<ConcurrentMemory>& sql, HistoryScope scope, bool preload = false);
      // A scope's directory is bound by its key, which `keys` resolves into `key`.
      static void bindScope(Statement& statement, HistoryScope scope, const HistoryScopeValue& value, DirectoryKeys& keys, FixedText<PATH_MAX>& key);
      // What a prune and a rewrite match, after a WHERE: its text, failure, age and scope, and
      // never a running command, which would come back as it finished.
      static void appendPruneFilters(ds::String<ConcurrentMemory>& sql, const RewriteHistory& request);
      static void bindPruneFilters(Statement& statement, const RewriteHistory& request, DirectoryKeys& keys, FixedText<PATH_MAX>& key);
      static void appendFilters(ds::String<ConcurrentMemory>& sql, const QueryHistory& request);
      static void bindFilters(Statement& statement, const QueryHistory& request, DirectoryKeys& keys, FixedText<PATH_MAX>& key);

      ConcurrentMemory& memory_;
      const HistoryFilters& filters_;
      // The writer's: where what the filters redact is written.
      HistoryRedaction redaction_;
      ds::String<ConcurrentMemory> path_;
      FixedText<max_history_host_bytes> host_;
      DirectoryKeys keys_;
      Database database_;
      ds::Option<Database> reader_;
      // One connection serves both lanes of an in-memory history, under this lock.
      std::mutex shared_connection_;
      bool lanes_ = false;
      bool indexed_ = false;

      // The writer's.
      HistoryChangeLog log_;
      bool prepared_ = false;
      // Published by the writer once the file is of the current version, read by the reader.
      std::atomic<bool> upgraded_{false};
      ds::Option<AgentCommandWriter> agent_commands_;
      ds::Option<PaneHistoryWriter> pane_writer_;
      ds::Option<LaunchHistoryWriter> launch_writer_;
      bool batch_open_ = false;
      std::size_t batch_count_ = 0;
      std::chrono::steady_clock::time_point batch_started_;
      std::int64_t maintained_ms_ = 0;
      // The newest run retention's keep_runs has seen, for the keep it applied; 0 for none yet.
      std::int64_t deduplicated_id_ = 0;
      std::uint32_t deduplicated_keep_ = 0;
      bool vacuum_checked_ = false;
      HistoryIndexFeed feed_;
      HistoryNotices notices_;

      // The reader's.
      HistoryRows rows_;
      HistoryIndex index_;
      ds::Vec<HistoryIndexFeed::Change, ConcurrentMemory> applying_;
      ds::Option<Statement> detail_;
      ds::Option<Statement> facts_;
      // The matcher's arena, made with the first query.
      ds::Option<HistoryMatchWork> match_scratch_;
      ds::String<ConcurrentMemory> plain_;
      FixedText<PATH_MAX> scope_key_;
      FixedText<PATH_MAX> origin_key_;
      FixedText<PATH_MAX> workspace_key_;
    };

  }
}

// What the store's units share and no importer reads.
namespace telar::runtime {

  // Registers on `database` the functions the history's SQL calls: telar_fold and telar_hash.
  void registerHistoryFunctions(const Database& database);

  // Brings a history of version 5 to the current one: the steps that read and rewrite rows.
  void upgradeHistory(Database& database, ConcurrentMemory& memory);

  // Whether the history is of the current version, with nothing left to rewrite.
  bool historyCurrent(Database& database);

}
