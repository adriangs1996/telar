#pragma once

#include "../diagnostics/trace.hpp"
#include "database.hpp"
#include "event.hpp"

namespace telar::runtime {

class PaneHistoryWriter {
public:
  explicit PaneHistoryWriter(Database &database)
      : database_(database),
        session_(database, session_sql),
        command_(database, command_sql),
        output_(database, output_sql),
        finish_(database, finish_sql),
        title_(database, title_sql) {}

  void persist(const HistoryEventView &event) {
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
  void ensureSession(const HistorySession &session) {
    session_.reset();
    bindContext(session_, session);
    session_.bind(7, session.shell);
    session_.bind(8, session.started_at_ms);
    session_.finish();
  }

  void insertCommand(const HistorySession &session, const CapturedCommand &command) {
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

  static void bindContext(Statement &statement, const HistorySession &session) {
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
