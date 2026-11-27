module telar.runtime.history.store;

import std;
import telar.sys.posix;
import telar.native.sqlite;
import telar.base.history;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    // The text of a function's single argument; none when it is NULL.
    ds::Option<std::string_view> argumentText(int count, sqlite3_value* const* values) {
      if (count != 1 || sqlite3_value_type(values[0]) == SQLITE_NULL) { // NOLINT(cppcoreguidelines-pro-bounds-pointer-arithmetic): SQLite hands the arguments as an array of count values
        return ds::none;
      }

      const auto* bytes = reinterpret_cast<const char*>(sqlite3_value_text(values[0])); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast,cppcoreguidelines-pro-bounds-pointer-arithmetic): SQLite's text is unsigned char

      return std::string_view{bytes == nullptr ? "" : bytes, static_cast<std::size_t>(sqlite3_value_bytes(values[0]))}; // NOLINT(cppcoreguidelines-pro-bounds-pointer-arithmetic): as above
    }

    // telar_fold(text): the text with historyFold's case fold, which a short query matches with
    // as the index's trigrams fold a longer one. Its scratch comes from SQLite, whose allocator
    // is the runtime's.
    void foldText(sqlite3_context* context, int count, sqlite3_value** values) { // NOLINT(misc-const-correctness): SQLite's function signature
      constexpr std::size_t small_text = 1024;
      const auto text = argumentText(count, values);
      if (!text) {
        sqlite3_result_null(context);
        return;
      }

      ds::Array<char, small_text> scratch; // NOLINT(cppcoreguidelines-pro-type-member-init): historyFold writes every byte SQLite copies
      std::span<char> out = scratch.viewMut();
      void* large = nullptr;

      if (text->size() > out.size()) {
        large = sqlite3_malloc64(text->size());
        if (large == nullptr) {
          sqlite3_result_error_nomem(context);
          return;
        }

        out = {static_cast<char*>(large), text->size()}; // NOLINT(clang-diagnostic-unsafe-buffer-usage-in-container): SQLite's allocation of exactly that size
      }

      const auto written = historyFold(*text, out);

      sqlite3_result_text(context, out.data(), static_cast<int>(written), SQLITE_TRANSIENT);
      sqlite3_free(large);
    }

    // telar_hash(text): the hash the history finds a command text by.
    void hashText(sqlite3_context* context, int count, sqlite3_value** values) { // NOLINT(misc-const-correctness): SQLite's function signature
      const auto text = argumentText(count, values);
      if (!text) {
        sqlite3_result_null(context);
        return;
      }

      sqlite3_result_int64(context, HistoryTexts::hash(*text));
    }

    bool tableExists(Database& database, const char* table) {
      Statement found{database, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1"};

      found.bind(1, std::string_view{table});
      return found.next();
    }

    bool columnExists(Database& database, const char* table, const char* column) { // NOLINT(bugprone-easily-swappable-parameters): a table and one of its columns, as pragma_table_info reads them
      Statement found{database, "SELECT 1 FROM pragma_table_info(?1) WHERE name = ?2"};

      found.bind(1, std::string_view{table});
      found.bind(2, std::string_view{column});
      return found.next();
    }

    std::int64_t version(Database& database) {
      Statement read{database, "SELECT version FROM history_schema"};

      return read.next() ? read.integer(0) : 0;
    }

    // Outputs stored before the tracker dropped the shell integration's marks keep them, and the
    // pane's token they carry: version 6 strips them, once.
    void stripOutputMarks(Database& database, ConcurrentMemory& memory) {
      constexpr std::int64_t stripped_version = 6;

      if (version(database) >= stripped_version) {
        return;
      }

      Transaction transaction{database};
      Statement rows{database, "SELECT command_id, content FROM command_output WHERE instr(content, char(27) || ']133') > 0 OR instr(content, char(27) || ']6973') > 0"};
      Statement update{database, "UPDATE command_output SET content = ?2 WHERE command_id = ?1"};
      ds::String<ConcurrentMemory> kept{memory};

      while (rows.next()) {
        const auto content = rows.text(1);
        IntegrationMarkFilter marks;

        kept.clear();
        marks.feed(byteView(content), [&](std::span<const std::uint8_t> run) {
          kept.append({reinterpret_cast<const char*>(run.data()), run.size()}); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the output's bytes as text
        });

        update.reset();
        update.bind(1, rows.integer(0));
        update.bind(2, kept.view());
        update.finish();
      }

      Statement{database, "UPDATE history_schema SET version = 6 WHERE version < 6"}.finish();
      transaction.commit();
    }

    // Commands stored before the history kept their directories' keys have none, and a scope
    // would miss them: version 7 gives each its keys, once. Read in the order of the directory,
    // each one is resolved once however many commands ran in it.
    void keyDirectories(Database& database, ConcurrentMemory& memory) {
      constexpr std::int64_t keyed_version = 7;

      if (version(database) >= keyed_version) {
        return;
      }

      struct KeyedColumn {
        std::string_view rows;
        std::string_view update;
      };

      constexpr ds::Array columns{
          KeyedColumn{.rows = "SELECT id, cwd FROM command WHERE cwd_key = '' AND cwd != '' ORDER BY cwd", .update = "UPDATE command SET cwd_key = ?2 WHERE id = ?1"},
          KeyedColumn{.rows = "SELECT id, workspace_path FROM command WHERE workspace_key = '' AND workspace_path != '' ORDER BY workspace_path", .update = "UPDATE command SET workspace_key = ?2 WHERE id = ?1"},
      };

      Transaction transaction{database};
      ds::String<ConcurrentMemory> path{memory};
      ds::String<ConcurrentMemory> key{memory};

      for (const auto& column : columns) {
        Statement rows{database, column.rows};
        Statement update{database, column.update};

        path.clear();
        key.clear();
        while (rows.next()) {
          if (const auto directory = rows.text(1); key.view().empty() || directory != path.view()) {
            ds::Array<char, PATH_MAX> buffer; // NOLINT(cppcoreguidelines-pro-type-member-init): resolveDirectoryKey writes what it views

            path.assign(directory);
            key.assign(resolveDirectoryKey(directory, buffer));
          }

          update.reset();
          update.bind(1, rows.integer(0));
          update.bind(2, key.view());
          update.finish();
        }
      }

      Statement{database, "UPDATE history_schema SET version = 7 WHERE version < 7"}.finish();
      transaction.commit();
    }

    // Before version 8 each run held its command's text, so a list of each command once read
    // every run, and deleting every run of a command scanned them all. Version 8 keeps each text
    // once, which the runs refer to, and gives each run its machine, branch and shell. The runs
    // move whole into the new table, ids, outputs and all; a run a shell interrupted, which
    // older releases kept as failed, is interrupted. The table's references are kept as written
    // while it is renamed, so the outputs keep naming the runs, now in the new table.
    void normalizeCommands(Database& database) {
      if (version(database) >= history_version) {
        return;
      }

      if (!columnExists(database, "command", "command")) {
        Statement{database, "UPDATE history_schema SET version = 8 WHERE version < 8"}.finish();
        return;
      }

      // One pass over the runs with a large cache and sorts in memory; the indexes are built once
      // the runs are copied, and the file is vacuumed later, when the writer idles.
      database.execute("PRAGMA foreign_keys = OFF; PRAGMA legacy_alter_table = ON; PRAGMA cache_size = -131072; PRAGMA temp_store = MEMORY;");

      try {
        database.execute("BEGIN IMMEDIATE");
        database.execute(R"sql(
DROP TRIGGER IF EXISTS command_fts_insert;
DROP TRIGGER IF EXISTS command_fts_delete;
DROP TRIGGER IF EXISTS command_fts_update;
DROP TABLE IF EXISTS command_fts;
DROP INDEX IF EXISTS command_started_at;
DROP INDEX IF EXISTS command_session_started;
DROP INDEX IF EXISTS command_pane_started;
DROP INDEX IF EXISTS command_exit_started;
DROP INDEX IF EXISTS command_cwd_key_started;
DROP INDEX IF EXISTS command_workspace_key_started;
DROP INDEX IF EXISTS command_cwd_started;
DROP INDEX IF EXISTS command_workspace_started;
DROP INDEX IF EXISTS command_tool_call;
ALTER TABLE command RENAME TO command_v7;
)sql");
        database.execute(history_schema);
        database.execute(history_runs);
        database.execute(R"sql(
INSERT INTO command_text(hash, text) SELECT telar_hash(command), command FROM command_v7 GROUP BY command;
INSERT INTO command (
  id, session_id, pane_id, location_kind, location_id, tab_id, sequence, text_id, command_truncated,
  cwd, workspace_path, started_at_ms, duration_ns, exit_code, status, author, origin, provider,
  tool_call_id, cwd_key, workspace_key, host, branch, shell
)
SELECT o.id, o.session_id, o.pane_id, o.location_kind, o.location_id, o.tab_id, o.sequence, t.id, o.command_truncated,
  o.cwd, o.workspace_path, o.started_at_ms, o.duration_ns, o.exit_code,
  CASE WHEN o.status = 0 AND o.exit_code IN (130, 141) THEN 1 ELSE o.status END,
  o.author, o.origin, o.provider, o.tool_call_id, o.cwd_key, o.workspace_key, '', '',
  COALESCE((SELECT s.shell FROM session s WHERE s.id = o.session_id), '')
FROM command_v7 o JOIN command_text t ON t.hash = telar_hash(o.command) AND t.text = o.command
ORDER BY o.id;
DROP TABLE command_v7;
)sql");
        database.execute(history_run_indexes);
        database.execute("UPDATE history_schema SET version = 8 WHERE version < 8; COMMIT;");
      } catch (...) {
        database.tryExecute("ROLLBACK");
        database.tryExecute("PRAGMA legacy_alter_table = OFF; PRAGMA foreign_keys = ON; PRAGMA cache_size = -2000; PRAGMA temp_store = DEFAULT;");
        throw;
      }

      database.execute("PRAGMA legacy_alter_table = OFF; PRAGMA foreign_keys = ON; PRAGMA cache_size = -2000; PRAGMA temp_store = DEFAULT;");
    }

  }

  void registerHistoryFunctions(const Database& database) {
    const int flags = combineFlags(SQLITE_UTF8, SQLITE_DETERMINISTIC, SQLITE_INNOCUOUS);

    checkSqlite(sqlite3_create_function_v2(database.handle(), "telar_fold", 1, flags, nullptr, foldText, nullptr, nullptr, nullptr));
    checkSqlite(sqlite3_create_function_v2(database.handle(), "telar_hash", 1, flags, nullptr, hashText, nullptr, nullptr, nullptr));
  }

  void migrateHistory(Database& database) {
    registerHistoryFunctions(database);
    bool fresh = false;

    {
      Statement tables{database, "SELECT COUNT(*) FROM sqlite_master"};

      fresh = tables.next() && tables.integer(0) == 0;
    }

    // Set before the first table, which is the only time a file takes it without a vacuum.
    if (fresh) {
      database.execute("PRAGMA auto_vacuum = INCREMENTAL");
    }

    database.execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON; CREATE TABLE IF NOT EXISTS history_schema (version INTEGER NOT NULL);");
    if (!tableExists(database, "command")) {
      database.execute(history_schema);
      database.execute(history_runs);
      database.execute(history_run_indexes);
      database.execute("INSERT INTO history_schema(version) SELECT 8 WHERE NOT EXISTS (SELECT 1 FROM history_schema); UPDATE history_schema SET version = 8 WHERE version < 8;");
      return;
    }

    database.execute("INSERT INTO history_schema(version) SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM history_schema)");
    if (version(database) >= history_version) {
      database.execute(history_schema);
      database.execute(history_runs);
      database.execute(history_run_indexes);
      return;
    }

    // An older history: the columns each release added, then what versions 6 to 8 rewrite.
    database.execute(history_schema);
    database.execute(R"sql(
CREATE TABLE IF NOT EXISTS command_output (
  command_id INTEGER PRIMARY KEY REFERENCES command(id) ON DELETE CASCADE,
  content TEXT NOT NULL,
  truncated INTEGER NOT NULL,
  observed_bytes INTEGER NOT NULL
);
)sql");

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
        Migration{.table = "command", .column = "cwd_key", .sql = "ALTER TABLE command ADD COLUMN cwd_key TEXT NOT NULL DEFAULT ''"},
        Migration{.table = "command", .column = "workspace_key", .sql = "ALTER TABLE command ADD COLUMN workspace_key TEXT NOT NULL DEFAULT ''"},
    };

    for (const auto& migration : migrations) {
      if (!columnExists(database, migration.table, migration.column)) {
        database.execute(migration.sql);
      }
    }

    database.execute("UPDATE history_schema SET version = 5 WHERE version < 5");
  }

  bool historyCurrent(Database& database) {
    return version(database) >= history_version && !columnExists(database, "command", "command");
  }

  void upgradeHistory(Database& database, ConcurrentMemory& memory) {
    stripOutputMarks(database, memory);
    keyDirectories(database, memory);
    normalizeCommands(database);
  }

  bool enableHistoryIndex(Database& database) {
    // The matcher reads every text itself, folded as it folds: the trigram index over the texts
    // an earlier build of this version made has no reader.
    database.tryExecute("DROP TRIGGER IF EXISTS command_text_fts_insert; DROP TRIGGER IF EXISTS command_text_fts_delete; DROP TABLE IF EXISTS command_text_fts;");

    // The outputs, without their control sequences, by their trigrams. The writer adds each one
    // it stores; the ones a deleted run takes with it are swept by the maintenance.
    if (tableExists(database, "command_output_fts")) {
      return true;
    }

    return database.tryExecute("CREATE VIRTUAL TABLE command_output_fts USING fts5(content, content='', contentless_delete=1, tokenize='trigram case_sensitive 0')");
  }

  namespace {

    // The byte just past the control sequence whose ESC is at `index`: ESC [ ... final,
    // ESC ] ... BEL or ST, ESC P/X/^/_ ... ST, or ESC and one byte.
    std::size_t pastEscape(std::string_view output, std::size_t index) noexcept {
      constexpr char escape = 0x1b;
      constexpr char bell = 0x07;
      constexpr unsigned char final_low = 0x40;
      constexpr unsigned char final_high = 0x7e;
      constexpr std::string_view strings = "]PX^_";
      const auto byte_at = [&](std::size_t offset) {
        return offset < output.size() ? output[offset] : '\0';
      };

      ++index;
      if (index >= output.size()) {
        return index;
      }

      const char kind = byte_at(index++);

      if (kind == '[') {
        while (index < output.size()) {
          const auto value = static_cast<unsigned char>(byte_at(index++));
          if (value >= final_low && value <= final_high) {
            return index;
          }
        }

        return index;
      }

      if (!strings.contains(kind)) {
        return index;
      }

      while (index < output.size()) {
        const char value = byte_at(index++);
        if (value == bell) {
          return index;
        }

        if (value == escape && byte_at(index) == '\\') {
          return index + 1;
        }
      }

      return index;
    }

  }

  void plainHistoryOutput(std::string_view output, ds::String<ConcurrentMemory>& out) {
    constexpr char escape = 0x1b;
    constexpr unsigned char first_printable = 0x20;
    constexpr unsigned char erase = 0x7f;

    out.clear();
    out.reserve(output.size());
    std::size_t index = 0;

    while (index < output.size()) {
      const char byte = output[index];

      if (byte == escape) {
        index = pastEscape(output, index);
        continue;
      }

      const auto value = static_cast<unsigned char>(byte);

      if (byte == '\n' || byte == '\t' || byte == '\r') {
        out.push(' ');
      } else if (value >= first_printable && value != erase) {
        out.push(byte);
      }

      ++index;
    }
  }

}
