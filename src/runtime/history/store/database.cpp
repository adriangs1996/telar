module telar.runtime.history.store;

import std;
import telar.tbc;
import telar.native.sqlite;
import telar.sys.posix;

import telar.runtime.host.descriptor_path;
import telar.platform.error;
import telar.platform.fs;
import telar.wire.vocabulary;
import telar.platform.primitives;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    ds::Array<char, PATH_MAX> prepareDatabaseFile(const char* path) {
      constexpr mode_t private_file_mode = 0600;
      ds::Array<char, PATH_MAX> canonical{};

      if (std::string_view{path} == ":memory:") {
        // The array is zeroed, so the copy stays terminated.
        std::ranges::copy(std::string_view{path}, canonical.viewMut().begin());
        return canonical;
      }

      const auto parent = openPrivateParent(path);
      const FileDescriptor file{::open(path, combineFlags(O_RDWR, O_CREAT, O_CLOEXEC, O_NOFOLLOW), private_file_mode)}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
      if (!file) {
        throw SystemError{"open history database"};
      }

      struct stat state{};
      if (::fstat(file.get(), &state) != 0 || !S_ISREG(state.st_mode) || state.st_uid != ::geteuid() || state.st_nlink != 1) {
        throw RequestError{FailureCode::permission_denied, "History database must be an owned regular file"};
      }

      if (::fchmod(file.get(), private_file_mode) != 0) {
        throw SystemError{"restrict history database permissions"};
      }

      canonical = descriptorPath(parent.get());

      const std::string_view parent_text{canonical.data(), canonical.size()};
      const auto parent_length = std::min(parent_text.find('\0'), parent_text.size());
      const std::string_view input{path};
      const auto filename = input.substr(input.rfind('/') + 1);
      if (parent_length + 1 + filename.size() >= canonical.size()) {
        throw SystemError{"history database path is too long", ENAMETOOLONG};
      }

      canonical.atMut(parent_length) = '/';
      std::ranges::copy(filename, canonical.viewMut().subspan(parent_length + 1).begin());
      return canonical;
    }

  }

  void checkSqlite(int result) {
    // An extended result code keeps its primary code in the low byte.
    constexpr unsigned primary_result_mask = 0xff;

    if (result == SQLITE_OK) {
      return;
    }

    if (static_cast<int>(static_cast<unsigned>(result) & primary_result_mask) == SQLITE_NOMEM) {
      throw std::bad_alloc{};
    }

    throw RequestError{FailureCode::internal, sqlite3_errstr(result)};
  }

  Database::Database(const char* path, DatabaseAccess access) {
    constexpr int reader_busy_timeout_ms = 200;
    constexpr int writer_busy_timeout_ms = 2000;
    const bool read_only = access == DatabaseAccess::read_only;
    const auto canonical = read_only ? ds::Array<char, PATH_MAX>{} : prepareDatabaseFile(path);
    const int flags = read_only ? combineFlags(SQLITE_OPEN_READONLY, SQLITE_OPEN_NOMUTEX) : combineFlags(SQLITE_OPEN_READWRITE, SQLITE_OPEN_CREATE, SQLITE_OPEN_NOMUTEX, SQLITE_OPEN_NOFOLLOW);
    const int result = sqlite3_open_v2(read_only ? path : canonical.data(), &database_, flags, nullptr);
    if (result != SQLITE_OK) {
      sqlite3_close(database_);
      database_ = nullptr;
      checkSqlite(result);
    }

    sqlite3_extended_result_codes(database_, 1);
    sqlite3_limit(database_, SQLITE_LIMIT_LENGTH, static_cast<int>(max_payload_size));
    sqlite3_busy_timeout(database_, read_only ? reader_busy_timeout_ms : writer_busy_timeout_ms);
  }

  Database::~Database() {
    // A connection with a statement left closes as a zombie that is never freed.
    for (const auto& kept : kept_.view()) {
      sqlite3_finalize(kept.statement);
    }

    sqlite3_close(database_);
  }

  void Database::execute(const char* sql) {
    checkSqlite(sqlite3_exec(database_, sql, nullptr, nullptr, nullptr));
  }

  bool Database::tryExecute(const char* sql) noexcept {
    return sqlite3_exec(database_, sql, nullptr, nullptr, nullptr) == SQLITE_OK;
  }

  sqlite3* Database::handle() const noexcept {
    return database_;
  }

  std::int64_t Database::changes() const noexcept {
    return sqlite3_changes64(database_);
  }

  void Database::interruptWhen(const std::atomic<bool>* cancelled) noexcept {
    // How many virtual machine steps run between two looks at the flag: a few microseconds.
    constexpr int steps = 4096;

    if (cancelled == nullptr) {
      sqlite3_progress_handler(database_, 0, nullptr, nullptr);
      return;
    }

    // SQLite's context is a void*, which the handler only reads through.
    void* flag = tbc::raw(const_cast<std::atomic<bool>*>(cancelled)); // NOLINT(cppcoreguidelines-pro-type-const-cast): as above

    sqlite3_progress_handler(database_, steps, [](void* context) noexcept -> int {
      return static_cast<const std::atomic<bool>*>(context)->load(std::memory_order_relaxed) ? 1 : 0;
    },
        flag);
  }

  Database::Prepared Database::prepared(std::string_view sql) {
    constexpr std::uint64_t offset_basis = 0xcbf29ce484222325;
    constexpr std::uint64_t prime = 0x100000001b3;
    std::uint64_t hash = offset_basis;

    for (const char byte : sql) {
      hash = (hash ^ static_cast<unsigned char>(byte)) * prime;
    }

    const auto same = [&](const Kept& kept) noexcept {
      return kept.statement != nullptr && kept.hash == hash && std::string_view{sqlite3_sql(kept.statement)} == sql;
    };

    Kept* room = nullptr;
    bool in_use = false;

    for (auto& kept : kept_.viewMut()) {
      if (same(kept)) {
        if (!kept.busy) {
          kept.busy = true;
          kept.used = ++kept_clock_;
          return {.statement = kept.statement, .kept = true};
        }

        in_use = true;
      }

      if (!kept.busy && (room == nullptr || kept.used < room->used)) {
        room = &kept;
      }
    }

    sqlite3_stmt* statement = nullptr;
    const bool keep = !in_use && room != nullptr;

    // Without SQLITE_PREPARE_PERSISTENT: that hint keeps a statement out of the connection's
    // lookaside memory, and a run then reads a row of the history 13 us slower (35 us to 48 us
    // for an entry, history-store-bench's inspect.entry), more than preparing it again costs.
    checkSqlite(sqlite3_prepare_v3(database_, sql.data(), static_cast<int>(sql.size()), 0, &statement, nullptr));
    if (!keep) {
      return {.statement = statement, .kept = false};
    }

    sqlite3_finalize(room->statement);
    *room = {.hash = hash, .used = ++kept_clock_, .statement = statement, .busy = true};
    return {.statement = statement, .kept = true};
  }

  void Database::release(sqlite3_stmt* statement) noexcept {
    // A failed step left its error with the statement, which its caller already had.
    static_cast<void>(sqlite3_reset(statement));
    static_cast<void>(sqlite3_clear_bindings(statement));

    for (auto& kept : kept_.viewMut()) {
      if (kept.statement == statement) {
        kept.busy = false;
        return;
      }
    }
  }

  Transaction::Transaction(Database& database)
      : database_(database) {
    database_.execute("BEGIN IMMEDIATE");
  }

  Transaction::~Transaction() {
    if (!committed_) {
      database_.tryExecute("ROLLBACK");
    }
  }

  void Transaction::commit() {
    database_.execute("COMMIT");
    committed_ = true;
  }

  WriteScope::WriteScope(Database& database)
      : database_(database) {
    database_.execute("SAVEPOINT history_write");
  }

  WriteScope::~WriteScope() {
    if (!committed_) {
      database_.tryExecute("ROLLBACK TO history_write");
      database_.tryExecute("RELEASE history_write");
    }
  }

  void WriteScope::commit() {
    database_.execute("RELEASE history_write");
    committed_ = true;
  }

  Statement::Statement(Database& database, std::string_view sql, Preparation preparation) {
    if (preparation == Preparation::once) {
      checkSqlite(sqlite3_prepare_v3(database.handle(), sql.data(), static_cast<int>(sql.size()), 0, &statement_, nullptr));
      return;
    }

    const auto prepared = database.prepared(sql);

    statement_ = prepared.statement;
    keeper_ = prepared.kept ? &database : nullptr;
  }

  Statement::~Statement() {
    if (keeper_ != nullptr) {
      keeper_->release(statement_);
    } else {
      sqlite3_finalize(statement_);
    }
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

  void Statement::bind(int index, ds::Option<std::int32_t> value) {
    if (value) {
      bind(index, std::int64_t{*value});
    } else {
      bindNull(index);
    }
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
    const auto* bytes = sqlite3_column_text(statement_, column);
    const auto length = sqlite3_column_bytes(statement_, column);

    if (bytes == nullptr) {
      if (sqlite3_errcode(sqlite3_db_handle(statement_)) == SQLITE_NOMEM) {
        throw std::bad_alloc{};
      }

      return {};
    }

    return {reinterpret_cast<const char*>(bytes), static_cast<std::size_t>(length)}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): SQLite hands text as unsigned char, which char may alias
  }

  bool Statement::isNull(int column) const noexcept {
    return sqlite3_column_type(statement_, column) == SQLITE_NULL;
  }

}
