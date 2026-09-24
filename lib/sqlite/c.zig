//! The SQLite C API. Every telar caller reaches it through this one import.

pub const c = @cImport({
    @cInclude("sqlite3.h");
});
