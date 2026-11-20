module;
#include <sqlite3.h>

export module telar.native.sqlite;

// SQLite's header stays in this global module fragment only; importers reach it through these
// declarations instead of including it.
export {
  using ::sqlite3;
  using ::sqlite3_mem_methods;
  using ::sqlite3_stmt;

  using ::sqlite3_bind_blob;
  using ::sqlite3_bind_int64;
  using ::sqlite3_bind_null;
  using ::sqlite3_bind_text;
  using ::sqlite3_busy_timeout;
  using ::sqlite3_changes;
  using ::sqlite3_changes64;
  using ::sqlite3_clear_bindings;
  using ::sqlite3_close;
  using ::sqlite3_column_bytes;
  using ::sqlite3_column_int64;
  using ::sqlite3_column_text;
  using ::sqlite3_column_type;
  using ::sqlite3_config;
  using ::sqlite3_db_handle;
  using ::sqlite3_errcode;
  using ::sqlite3_errstr;
  using ::sqlite3_exec;
  using ::sqlite3_extended_result_codes;
  using ::sqlite3_finalize;
  using ::sqlite3_initialize;
  using ::sqlite3_limit;
  using ::sqlite3_open_v2;
  using ::sqlite3_prepare_v3;
  using ::sqlite3_reset;
  using ::sqlite3_shutdown;
  using ::sqlite3_step;
}

// Macros do not cross an import. Each constant the tree reads is captured while the header still
// defines it, undefined, and exported under its own name.
// NOLINTNEXTLINE(cppcoreguidelines-macro-usage): only a macro can read a macro's value before the header's #undef.
#define TELAR_SQLITE_CONSTANTS(X) \
  X(SQLITE_CONFIG_GETMALLOC)      \
  X(SQLITE_CONFIG_MALLOC)         \
  X(SQLITE_DONE)                  \
  X(SQLITE_LIMIT_LENGTH)          \
  X(SQLITE_NOMEM)                 \
  X(SQLITE_NULL)                  \
  X(SQLITE_OK)                    \
  X(SQLITE_OPEN_CREATE)           \
  X(SQLITE_OPEN_NOFOLLOW)         \
  X(SQLITE_OPEN_NOMUTEX)          \
  X(SQLITE_OPEN_READONLY)         \
  X(SQLITE_OPEN_READWRITE)        \
  X(SQLITE_ROW)

namespace telar::native::sqlite::captured {

#define TELAR_SQLITE_CAPTURE(name) inline constexpr auto name##_ = name;
  TELAR_SQLITE_CONSTANTS(TELAR_SQLITE_CAPTURE)

}

#undef SQLITE_CONFIG_GETMALLOC
#undef SQLITE_CONFIG_MALLOC
#undef SQLITE_DONE
#undef SQLITE_LIMIT_LENGTH
#undef SQLITE_NOMEM
#undef SQLITE_NULL
#undef SQLITE_OK
#undef SQLITE_OPEN_CREATE
#undef SQLITE_OPEN_NOFOLLOW
#undef SQLITE_OPEN_NOMUTEX
#undef SQLITE_OPEN_READONLY
#undef SQLITE_OPEN_READWRITE
#undef SQLITE_ROW

#define TELAR_SQLITE_CONSTANT(name) inline constexpr auto name = telar::native::sqlite::captured::name##_;

export {
  TELAR_SQLITE_CONSTANTS(TELAR_SQLITE_CONSTANT) // NOLINT(readability-identifier-naming): exported under the C library's own name
}

// SQLITE_TRANSIENT casts -1 to a destructor pointer, which no constant expression can do.
namespace telar::native::sqlite::captured {

  inline const auto SQLITE_TRANSIENT_ = SQLITE_TRANSIENT; // NOLINT(readability-identifier-naming): the capture of SQLite's macro, named after it

}

#undef SQLITE_TRANSIENT

export {
  inline const auto SQLITE_TRANSIENT = telar::native::sqlite::captured::SQLITE_TRANSIENT_; // NOLINT(readability-identifier-naming): exported under the C library's own name
}
