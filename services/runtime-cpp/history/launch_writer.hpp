#pragma once

#include "../diagnostics/trace.hpp"
#include "database.hpp"
#include "event.hpp"

namespace telar::runtime {

class LaunchHistoryWriter {
public:
  explicit LaunchHistoryWriter(Database &database)
      : insert_(database, insert_sql) {}

  void persist(const HistoryEventView &event) {
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
