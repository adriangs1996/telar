module telar.cli.commands.history.sources;

import std;
import telar.sys.posix;
import telar.native.sqlite;
import telar.platform.primitives;
import telar.cli.console.command_limit;
import telar.base.ds;

namespace telar::runtime::cli::history {

  namespace {

    constexpr std::string_view sqlite_magic{"SQLite format 3\0", 16};
    constexpr std::int64_t nanoseconds_per_millisecond = 1000000;
    constexpr std::int64_t milliseconds_per_second = 1000;
    constexpr std::size_t max_row_bytes = std::size_t{16} * 1024 * 1024;

    constexpr std::int64_t nanoseconds_per_second = 1000000000;

    // How each tool's database lists its commands, oldest first: when each started, the command,
    // the directory, the exit status and the duration, with the units the tool keeps them in.
    // atuin keeps nanoseconds and marks a deleted entry; zsh-histdb names each command and each
    // directory once and points its runs at them; mcfly keeps no duration.
    struct DatabaseQuery {
      std::string_view sql;
      std::int64_t milliseconds_per_unit;
      std::int64_t units_per_millisecond;
      std::int64_t nanoseconds_per_duration_unit;
    };

    DatabaseQuery query(ImportFormat format) {
      switch (format) {
      case ImportFormat::atuin:
        return {.sql = "SELECT timestamp, command, cwd, exit, duration FROM history WHERE deleted_at IS NULL ORDER BY timestamp, id", .milliseconds_per_unit = 1, .units_per_millisecond = nanoseconds_per_millisecond, .nanoseconds_per_duration_unit = 1};
      case ImportFormat::mcfly:
        return {.sql = "SELECT when_run, cmd, dir, exit_code, NULL FROM commands ORDER BY when_run, id", .milliseconds_per_unit = milliseconds_per_second, .units_per_millisecond = 1, .nanoseconds_per_duration_unit = 0};
      case ImportFormat::histdb:
        return {.sql = "SELECT history.start_time, commands.argv, places.dir, history.exit_status, history.duration FROM history JOIN commands ON commands.id = history.command_id LEFT JOIN places ON places.id = history.place_id ORDER BY history.start_time, history.id", .milliseconds_per_unit = milliseconds_per_second, .units_per_millisecond = 1, .nanoseconds_per_duration_unit = nanoseconds_per_second};
      case ImportFormat::nushell_sqlite:
        return {.sql = "SELECT start_timestamp, command_line, cwd, exit_status, duration_ms FROM history ORDER BY start_timestamp, id", .milliseconds_per_unit = 1, .units_per_millisecond = 1, .nanoseconds_per_duration_unit = nanoseconds_per_millisecond};
      case ImportFormat::zsh:
      case ImportFormat::bash:
      case ImportFormat::fish:
      case ImportFormat::nushell:
      case ImportFormat::xonsh:
      case ImportFormat::powershell:
        break;
      }

      throw std::runtime_error{"UnknownHistoryImportKind"};
    }

    // A database another program owns, opened so that nothing in it runs or writes: read only,
    // through no symlink, with its schema distrusted, so a view or trigger it defines calls no
    // function with side effects.
    class ForeignDatabase {
    public:
      explicit ForeignDatabase(const char* path) {
        const auto opened = sqlite3_open_v2(path, &database_, combineFlags(SQLITE_OPEN_READONLY, SQLITE_OPEN_NOFOLLOW, SQLITE_OPEN_NOMUTEX), nullptr);
        if (opened != SQLITE_OK) {
          throw std::runtime_error{"HistoryDatabaseUnreadable"};
        }

        // A row past this fails the read instead of making SQLite hold it; one past
        // max_command_bytes is skipped as a histfile's is.
        sqlite3_limit(database_, SQLITE_LIMIT_LENGTH, static_cast<int>(max_row_bytes));
        if (sqlite3_exec(database_, "PRAGMA trusted_schema = OFF; PRAGMA query_only = ON;", nullptr, nullptr, nullptr) != SQLITE_OK) {
          throw std::runtime_error{"HistoryDatabaseUnreadable"};
        }
      }

      ~ForeignDatabase() {
        sqlite3_close(database_);
      }

      ForeignDatabase(const ForeignDatabase&) = delete;
      ForeignDatabase& operator=(const ForeignDatabase&) = delete;
      ForeignDatabase(ForeignDatabase&&) = delete;
      ForeignDatabase& operator=(ForeignDatabase&&) = delete;

      [[nodiscard]] sqlite3* handle() const noexcept {
        return database_;
      }

    private:
      sqlite3* database_ = nullptr;
    };

    class Rows {
    public:
      Rows(const ForeignDatabase& database, std::string_view sql) {
        if (sqlite3_prepare_v3(database.handle(), sql.data(), static_cast<int>(sql.size()), 0, &statement_, nullptr) != SQLITE_OK) {
          throw std::runtime_error{"HistoryDatabaseSchemaUnknown"};
        }
      }

      ~Rows() {
        sqlite3_finalize(statement_);
      }

      Rows(const Rows&) = delete;
      Rows& operator=(const Rows&) = delete;
      Rows(Rows&&) = delete;
      Rows& operator=(Rows&&) = delete;

      // Whether a row is ready; a command past SQLite's length limit fails the step, and the
      // database is then read no further.
      bool next() {
        const auto result = sqlite3_step(statement_);
        if (result == SQLITE_ROW) {
          return true;
        }

        if (result != SQLITE_DONE) {
          throw std::runtime_error{"HistoryDatabaseUnreadable"};
        }

        return false;
      }

      [[nodiscard]] std::int64_t integer(int column) const noexcept {
        return sqlite3_column_int64(statement_, column);
      }

      [[nodiscard]] bool isNull(int column) const noexcept {
        return sqlite3_column_type(statement_, column) == SQLITE_NULL;
      }

      [[nodiscard]] std::string_view text(int column) const noexcept {
        if (sqlite3_column_type(statement_, column) == SQLITE_NULL) {
          return {};
        }

        const auto* bytes = reinterpret_cast<const char*>(sqlite3_column_text(statement_, column)); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): SQLite's text is unsigned char
        const auto size = static_cast<std::size_t>(sqlite3_column_bytes(statement_, column));

        return bytes == nullptr ? std::string_view{} : std::string_view{bytes, size};
      }

    private:
      sqlite3_stmt* statement_ = nullptr;
    };

    std::int64_t scaled(std::int64_t value, const DatabaseQuery& query) noexcept {
      const auto limit = std::numeric_limits<std::int64_t>::max() / query.milliseconds_per_unit;

      if (value < 0) {
        return 0;
      }

      return std::min(value, limit) * query.milliseconds_per_unit / query.units_per_millisecond;
    }

    // A duration the database keeps, in nanoseconds; 0 for one it does not know or that is negative.
    std::int64_t duration(const Rows& rows, int column, const DatabaseQuery& query) noexcept {
      if (query.nanoseconds_per_duration_unit == 0 || rows.isNull(column) || rows.integer(column) <= 0) {
        return 0;
      }

      return std::min(rows.integer(column), std::numeric_limits<std::int64_t>::max() / query.nanoseconds_per_duration_unit) * query.nanoseconds_per_duration_unit;
    }

    // An exit status that fits a 32-bit integer, as a shell reports one.
    ds::Option<std::int32_t> exitStatus(const Rows& rows, int column) noexcept {
      const auto value = rows.integer(column);
      if (rows.isNull(column) || value < std::numeric_limits<std::int32_t>::min() || value > std::numeric_limits<std::int32_t>::max()) {
        return ds::none;
      }

      return static_cast<std::int32_t>(value);
    }

  }

  bool sqliteFile(const char* path) noexcept {
    const FileDescriptor file{::open(path, combineFlags(O_RDONLY, O_NOFOLLOW, O_NONBLOCK, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
    ds::Array<char, sqlite_magic.size()> header{};

    return file && ::pread(file.get(), header.dataMut(), header.size(), 0) == static_cast<ssize_t>(header.size()) && std::string_view{header.data(), header.size()} == sqlite_magic;
  }

  void readDatabase(ImportFormat format, const char* path, ImportSink& sink) {
    struct stat inode{};
    if (::lstat(path, &inode) != 0) {
      throw std::runtime_error{sys::errorName(sys::lastError())};
    }

    if (!S_ISREG(inode.st_mode)) {
      throw std::runtime_error{"HistfileNotRegular"};
    }

    if (std::cmp_greater(inode.st_size, max_database_bytes)) {
      reportCommandLimit({.name = "history.max_database_bytes", .noun = "bytes", .value = max_database_bytes, .requested = static_cast<std::uint64_t>(inode.st_size)});
      throw std::runtime_error{"HistoryDatabaseTooLarge"};
    }

    if (!sqliteFile(path)) {
      throw std::runtime_error{"HistoryDatabaseUnreadable"};
    }

    const auto selected = query(format);
    const ForeignDatabase database{path};
    Rows rows{database, selected.sql};

    while (rows.next()) {
      const auto command = rows.text(1);
      if (command.size() > max_command_bytes) {
        sink.skipped(command.size());
      } else if (!command.empty()) {
        constexpr int cwd_column = 2;
        constexpr int exit_column = 3;
        constexpr int duration_column = 4;

        sink.command(scaled(rows.integer(0), selected), command, {.cwd = rows.text(cwd_column), .exit_code = exitStatus(rows, exit_column), .duration_ns = duration(rows, duration_column, selected)});
      }
    }
  }

}
