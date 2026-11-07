module;
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>
#include <type_traits>
#include <optional>
#include <string>
#include <variant>
#include <vector>
#include <bit>
#include <stdexcept>
#include <utility>

#include <exception>
#include <sqlite3.h>
#include <cerrno>
#include <array>
#include <cstdio>
#include <fcntl.h>
#include <limits.h>
#include <limits>
#include <unistd.h>
#include <algorithm>
#include <string_view>
#include <sys/stat.h>
#include <cstring>

module telar.runtime.history.store;

import telar.runtime.platform.system_certificates;
import telar.platform;
import telar.client.protocol;
import telar.platform.primitives;


namespace telar::runtime {

void checkSqlite(int result) {
  if (result == SQLITE_OK) {
    return;
  }

  if ((result & 0xff) == SQLITE_NOMEM) {
    throw std::bad_alloc{};
  }

  throw RequestError{FailureCode::internal, sqlite3_errstr(result)};
}

static std::array<char, PATH_MAX> prepareDatabaseFile(const char *path) {
  std::array<char, PATH_MAX> canonical{};
  if (std::string_view{path} == ":memory:") {
    std::memcpy(canonical.data(), path, sizeof(":memory:"));
    return canonical;
  }

  auto parent = openPrivateParent(path);
  FileDescriptor file{::open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600)};
  if (!file) {
    throw SystemError{"open history database"};
  }

  struct stat state{};
  if (::fstat(file.get(), &state) != 0 || !S_ISREG(state.st_mode) || state.st_uid != ::geteuid() || state.st_nlink != 1) {
    throw RequestError{FailureCode::permission_denied, "History database must be an owned regular file"};
  }

  if (::fchmod(file.get(), 0600) != 0) {
    throw SystemError{"restrict history database permissions"};
  }

  canonical = descriptorPath(parent.get());

  const auto parent_length = std::strlen(canonical.data());
  const std::string_view input{path};
  const auto filename = input.substr(input.rfind('/') + 1);
  if (parent_length + 1 + filename.size() >= canonical.size()) {
    throw SystemError{"history database path is too long", ENAMETOOLONG};
  }

  canonical[parent_length] = '/';
  std::memcpy(canonical.data() + parent_length + 1, filename.data(), filename.size());
  return canonical;
}

Database::Database(const char *path, DatabaseAccess access) {
  const bool read_only = access == DatabaseAccess::read_only;
  const auto canonical = read_only ? std::array<char, PATH_MAX>{} : prepareDatabaseFile(path);
  const int flags = read_only ? SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW;
  const int result = sqlite3_open_v2(read_only ? path : canonical.data(), &database_, flags, nullptr);
  if (result != SQLITE_OK) {
    sqlite3_close(database_);
    database_ = nullptr;
    checkSqlite(result);
  }

  sqlite3_extended_result_codes(database_, 1);
  sqlite3_limit(database_, SQLITE_LIMIT_LENGTH, static_cast<int>(max_payload_size));
  sqlite3_busy_timeout(database_, read_only ? 200 : 2000);
}

Database::~Database() {
  sqlite3_close(database_);
}

void Database::execute(const char *sql) {
  checkSqlite(sqlite3_exec(database_, sql, nullptr, nullptr, nullptr));
}

bool Database::tryExecute(const char *sql) noexcept {
  return sqlite3_exec(database_, sql, nullptr, nullptr, nullptr) == SQLITE_OK;
}

Statement::Statement(Database &database, std::string_view sql) {
  checkSqlite(sqlite3_prepare_v3(database.handle(), sql.data(), static_cast<int>(sql.size()), 0, &statement_, nullptr));
}

Statement::~Statement() {
  sqlite3_finalize(statement_);
}

void Statement::bind(int index, std::int64_t value) {
  checkSqlite(sqlite3_bind_int64(statement_, index, value));
}

void Statement::bind(int index, std::string_view value) {
  checkSqlite(sqlite3_bind_text(statement_, index, value.empty() ? "" : value.data(), static_cast<int>(value.size()), SQLITE_TRANSIENT));
}

void Statement::bind(int index, std::span<const Byte> value) {
  checkSqlite(sqlite3_bind_blob(statement_, index, value.data(), static_cast<int>(value.size()), SQLITE_TRANSIENT));
}

void Statement::bindNull(int index) {
  checkSqlite(sqlite3_bind_null(statement_, index));
}

bool Statement::next() {
  const int result = sqlite3_step(statement_);
  if (result == SQLITE_ROW) {
    return true;
  }

  if (result == SQLITE_DONE) {
    return false;
  }

  checkSqlite(result);
  return false;
}

void Statement::finish() {
  if (next()) {
    throw RequestError{FailureCode::internal, "Unexpected history result row"};
  }
}

void Statement::reset() {
  checkSqlite(sqlite3_reset(statement_));
  checkSqlite(sqlite3_clear_bindings(statement_));
}

std::int64_t Statement::integer(int column) const noexcept {
  return sqlite3_column_int64(statement_, column);
}

std::string_view Statement::text(int column) const {
  const auto *bytes = sqlite3_column_text(statement_, column);
  const auto length = sqlite3_column_bytes(statement_, column);
  if (bytes == nullptr) {
    if (sqlite3_errcode(sqlite3_db_handle(statement_)) == SQLITE_NOMEM) {
      throw std::bad_alloc{};
    }
    return {};
  }

  return {reinterpret_cast<const char *>(bytes), static_cast<std::size_t>(length)};
}

bool Statement::isNull(int column) const noexcept {
  return sqlite3_column_type(statement_, column) == SQLITE_NULL;
}

}
