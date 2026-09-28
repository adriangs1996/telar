//! The one SQLite binding: the C API, prepared-statement helpers, additive
//! schema migrations, FTS5 query quoting and the allocator SQLite uses.
const statement = @import("statement.zig");
const schema = @import("schema.zig");
const fts = @import("fts.zig");
const memory = @import("memory.zig");

pub const c = @import("c.zig").c;
pub const ColumnMigration = @import("ColumnMigration.zig");
pub const prepare = statement.prepare;
pub const stepDone = statement.stepDone;
pub const reset = statement.reset;
pub const bindText = statement.bindText;
pub const bindBlob = statement.bindBlob;
pub const columnSlice = statement.columnSlice;
pub const columnText = statement.columnText;
pub const tableExists = schema.tableExists;
pub const ensureColumn = schema.ensureColumn;
pub const ftsQuote = fts.quote;
pub const routeMemory = memory.routeMemory;

test {
    _ = @import("fts.zig");
    _ = @import("memory.zig");
    _ = @import("schema.zig");
    _ = @import("statement.zig");
}
