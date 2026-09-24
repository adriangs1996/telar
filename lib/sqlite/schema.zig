//! Schema probes and additive migrations.
const std = @import("std");
const c = @import("c.zig").c;
const statement = @import("statement.zig");
const ColumnMigration = @import("ColumnMigration.zig");

/// Whether `name` is a table in the main schema.
///
/// ```zig
/// if (!try schema.tableExists(db, "command_fts")) try createIndex(db);
/// ```
pub fn tableExists(db: *c.sqlite3, name: []const u8) !bool {
    const stmt = try statement.prepare(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?;");
    defer _ = c.sqlite3_finalize(stmt);
    statement.bindText(stmt, 1, name);
    return switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => true,
        c.SQLITE_DONE => false,
        else => error.SqliteSchemaFailed,
    };
}

/// Runs `migration.alter_sql` unless the column already exists.
///
/// ```zig
/// try schema.ensureColumn(db, .{ .table = "command", .column = "origin", .alter_sql = alter });
/// ```
pub fn ensureColumn(db: *c.sqlite3, migration: ColumnMigration) !void {
    var pragma_buffer: [64]u8 = undefined;
    const pragma = try std.fmt.bufPrint(&pragma_buffer, "PRAGMA table_info({s});", .{migration.table});
    const stmt = try statement.prepare(db, pragma);
    defer _ = c.sqlite3_finalize(stmt);
    while (true) switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => {
            if (std.mem.eql(u8, statement.columnSlice(stmt, 1), migration.column)) {
                return;
            }
        },
        c.SQLITE_DONE => break,
        else => return error.SqliteSchemaFailed,
    };

    if (c.sqlite3_exec(db, migration.alter_sql.ptr, null, null, null) != c.SQLITE_OK) {
        return error.SqliteSchemaFailed;
    }
}

test "a missing column is added once" {
    var db: ?*c.sqlite3 = null;
    try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_open(":memory:", &db));
    defer _ = c.sqlite3_close(db);
    try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_exec(db, "CREATE TABLE t (a INTEGER);", null, null, null));

    try std.testing.expect(try tableExists(db.?, "t"));
    try std.testing.expect(!try tableExists(db.?, "missing"));

    const migration: ColumnMigration = .{
        .table = "t",
        .column = "b",
        .alter_sql = "ALTER TABLE t ADD COLUMN b INTEGER;",
    };
    try ensureColumn(db.?, migration);
    try ensureColumn(db.?, migration);
}
