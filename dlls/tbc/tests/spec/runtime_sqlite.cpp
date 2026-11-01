#include "support.hpp"

// CASE: runtime.sqlite_next_invalidates
// PAIR: runtime.sqlite_next
// SOURCE: services/runtime-cpp/history/database.cpp :: Statement::text / Statement::next
// STATUS: pending
// CONTRACT: text borrows the current SQLite row; stepping ends that row's validity.
// SCENARIO: The statement survives, but the old row view must not survive next.
void sqliteNextInvalidates(tbc::view<spec::statement &> statement) {
  const auto row = statement.text();
  statement.next(); // expected-error [tbc-invalidated-borrow]
  spec::observe(row);
}

// END CASE

// CASE: runtime.sqlite_copy_survives_next
// PAIR: runtime.sqlite_next
// SOURCE: services/runtime-cpp/history/result_rows.hpp :: HistoryRows::append
// STATUS: pending
// CONTRACT: Copying row text into owned storage severs its SQLite-row dependency.
// SCENARIO: A copied string remains valid after stepping to the next row.
void sqliteCopySurvivesNext(tbc::view<spec::statement &> statement) {
  const auto copied = spec::copyText(statement.text());
  statement.next();
  spec::observe(copied);
}

// END CASE

// CASE: runtime.sqlite_reset_invalidates
// PAIR: runtime.sqlite_reset
// SOURCE: services/runtime-cpp/history/database.cpp :: Statement::reset
// STATUS: pending
// CONTRACT: reset invalidates row-backed views, independently of descriptor address stability.
// SCENARIO: Reject reset while an old row view will be read again.
void sqliteResetInvalidates(tbc::view<spec::statement &> statement) {
  const auto row = statement.text();
  statement.reset(); // expected-error [tbc-invalidated-borrow]
  spec::observe(row);
}

// END CASE

// CASE: runtime.sqlite_transient_bind
// PAIR: runtime.sqlite_reset
// SOURCE: services/runtime-cpp/history/database.cpp :: Statement::bind / SQLITE_TRANSIENT
// STATUS: pending
// CONTRACT: bind copies input; reset may invalidate old rows but cannot dangle a consumed input.
// SCENARIO: A temporary bind argument is safe; read only a newly acquired row afterward.
void sqliteTransientBind(tbc::view<spec::statement &> statement) {
  statement.bind(std::string{"copied by SQLITE_TRANSIENT"});
  statement.reset();
  spec::observe(statement.text());
}

// END CASE

// CASE: runtime.sqlite_statement_escape
// PAIR: runtime.sqlite_owner
// SOURCE: services/runtime-cpp/history/database.cpp :: Statement::~Statement / Statement::text
// STATUS: pending
// CONTRACT: Finalizing a statement ends the validity of its row storage.
// SCENARIO: Reject exporting a view backed by a local statement.
tbc::view<std::string_view, tbc::lt::a> sqliteStatementEscape() {
  const spec::statement statement;
  return statement.text(); // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: runtime.sqlite_owned_result
// PAIR: runtime.sqlite_owner
// SOURCE: services/runtime-cpp/history/result_rows.hpp :: HistoryRows::copy
// STATUS: pending
// CONTRACT: Return an owning copy instead of the SQLite-managed view.
// SCENARIO: Destroying the statement does not affect the returned string.
std::string sqliteOwnedResult() {
  const spec::statement statement;
  return spec::copyText(statement.text());
}

// END CASE
