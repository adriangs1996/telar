#pragma once

#include "../runtime/request_error.hpp"
#include <sqlite3.h>

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

  sqlite3 *handle() const noexcept {
    return database_;
  }

private:
  sqlite3 *database_ = nullptr;
};

class Statement {
public:
  explicit Statement(Database &database, std::string_view sql);
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
  sqlite3_stmt *statement_ = nullptr;
};

class Transaction {
public:
  explicit Transaction(Database &database)
      : database_(database) {
    database_.execute("BEGIN IMMEDIATE");
  }

  ~Transaction() {
    if (!committed_) {
      database_.tryExecute("ROLLBACK");
    }
  }

  void commit() {
    database_.execute("COMMIT");
    committed_ = true;
  }

private:
  Database &database_;
  bool committed_ = false;
};

}
