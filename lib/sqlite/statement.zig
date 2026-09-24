//! Prepared-statement helpers every caller repeats: prepare, step, reset,
//! bind and read a column.
const std = @import("std");
const c = @import("c.zig").c;

/// Compiles one statement. The caller finalizes it.
///
/// ```zig
/// const stmt = try statement.prepare(db, "SELECT 1;");
/// defer _ = c.sqlite3_finalize(stmt);
/// ```
pub fn prepare(db: *c.sqlite3, sql: []const u8) !*c.sqlite3_stmt {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) {
        return error.SqlitePrepareFailed;
    }

    return stmt orelse error.SqlitePrepareFailed;
}

/// Runs a statement that returns no rows.
///
/// ```zig
/// try statement.stepDone(stmt);
/// ```
pub fn stepDone(stmt: *c.sqlite3_stmt) !void {
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        return error.SqliteStepFailed;
    }
}

/// Makes a cached statement ready for its next bindings.
///
/// ```zig
/// defer statement.reset(stmt);
/// ```
pub fn reset(stmt: *c.sqlite3_stmt) void {
    _ = c.sqlite3_reset(stmt);
    _ = c.sqlite3_clear_bindings(stmt);
}

/// Binds borrowed text; `value` must outlive the step.
///
/// ```zig
/// statement.bindText(stmt, 1, name);
/// ```
pub fn bindText(stmt: *c.sqlite3_stmt, index: c_int, value: []const u8) void {
    _ = c.sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), null);
}

/// Binds borrowed bytes; `value` must outlive the step.
///
/// ```zig
/// statement.bindBlob(stmt, 1, &id);
/// ```
pub fn bindBlob(stmt: *c.sqlite3_stmt, index: c_int, value: []const u8) void {
    _ = c.sqlite3_bind_blob(stmt, index, value.ptr, @intCast(value.len), null);
}

/// Borrows a text column, empty when NULL; valid only until the next step
/// or reset.
///
/// ```zig
/// const name = statement.columnSlice(stmt, 0);
/// ```
pub fn columnSlice(stmt: *c.sqlite3_stmt, column: c_int) []const u8 {
    const pointer = c.sqlite3_column_text(stmt, column) orelse return "";
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, column));
    return pointer[0..len];
}

/// Copies a text column. The caller owns the result.
///
/// ```zig
/// const cwd = try statement.columnText(gpa, stmt, 7);
/// defer gpa.free(cwd);
/// ```
pub fn columnText(gpa: std.mem.Allocator, stmt: *c.sqlite3_stmt, column: c_int) ![]u8 {
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, column));
    if (len == 0) {
        return gpa.alloc(u8, 0);
    }

    const pointer = c.sqlite3_column_text(stmt, column) orelse return error.SqliteInvalidText;
    return gpa.dupe(u8, pointer[0..len]);
}

test "a statement binds, steps and reads text back" {
    var db: ?*c.sqlite3 = null;
    try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_open(":memory:", &db));
    defer _ = c.sqlite3_close(db);

    const create = try prepare(db.?, "CREATE TABLE t (name TEXT, id BLOB);");
    defer _ = c.sqlite3_finalize(create);
    try stepDone(create);

    const insert = try prepare(db.?, "INSERT INTO t VALUES (?, ?);");
    defer _ = c.sqlite3_finalize(insert);
    const id = [_]u8{ 1, 2, 3 };
    bindText(insert, 1, "telar");
    bindBlob(insert, 2, &id);
    try stepDone(insert);
    reset(insert);

    const select = try prepare(db.?, "SELECT name FROM t;");
    defer _ = c.sqlite3_finalize(select);
    try std.testing.expectEqual(@as(c_int, c.SQLITE_ROW), c.sqlite3_step(select));
    try std.testing.expectEqualStrings("telar", columnSlice(select, 0));

    const copy = try columnText(std.testing.allocator, select, 0);
    defer std.testing.allocator.free(copy);
    try std.testing.expectEqualStrings("telar", copy);
    try std.testing.expectError(error.SqlitePrepareFailed, prepare(db.?, "NOT SQL"));
}
