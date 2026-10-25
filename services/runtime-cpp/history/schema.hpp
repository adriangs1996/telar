#pragma once

#include "database.hpp"

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
