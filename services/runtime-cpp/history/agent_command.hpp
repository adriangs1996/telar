#pragma once

#include "../diagnostics/limit_ledger.hpp"
#include "../diagnostics/trace.hpp"
#include "../runtime/request_context.hpp"
#include "database.hpp"

namespace telar::runtime {

class AgentCommandWriter {
public:
  explicit AgentCommandWriter(Database &database)
      : database_(database),
        session_(database, session_sql),
        finish_(database, finish_sql),
        insert_(database, insert_sql) {}

  void persist(const ReportAgentCommand &request, const RequestContext &context) {
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
