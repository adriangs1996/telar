//! Routes SQLite's allocations through a Zig allocator instead of libc's
//! `malloc`. SQLite frees and sizes a block by its pointer alone, so each
//! block carries its length in a header before the bytes SQLite sees.
const std = @import("std");
const c = @import("c.zig").c;

/// SQLite requires 8-byte alignment; the header keeps it for the bytes after it.
const block_alignment: std.mem.Alignment = .@"8";
const header_len = block_alignment.toByteUnits();

const Block = []align(block_alignment.toByteUnits()) u8;

var routed: std.mem.Allocator = undefined;

const methods: c.sqlite3_mem_methods = .{
    .xMalloc = &allocate,
    .xFree = &release,
    .xRealloc = &reallocate,
    .xSize = &size,
    .xRoundup = &roundUp,
    .xInit = &start,
    .xShutdown = &stop,
    .pAppData = null,
};

/// Makes every later SQLite allocation of this process come from
/// `allocator`, which must be thread-safe and outlive SQLite. Call it before
/// the process opens any database; SQLite refuses it once initialized.
///
/// ```zig
/// try sqlite.routeMemory(slabheap.allocator);
/// ```
pub fn routeMemory(allocator: std.mem.Allocator) !void {
    routed = allocator;
    if (c.sqlite3_config(c.SQLITE_CONFIG_MALLOC, &methods) != c.SQLITE_OK) {
        return error.SqliteAlreadyInitialized;
    }
}

fn allocate(len: c_int) callconv(.c) ?*anyopaque {
    if (len <= 0) {
        return null;
    }

    const block = routed.alignedAlloc(u8, block_alignment, header_len + @as(usize, @intCast(len))) catch return null;
    return seal(block);
}

fn release(pointer: ?*anyopaque) callconv(.c) void {
    const bytes = pointer orelse return;
    routed.free(unseal(bytes));
}

fn reallocate(pointer: ?*anyopaque, len: c_int) callconv(.c) ?*anyopaque {
    const bytes = pointer orelse return allocate(len);
    if (len <= 0) {
        release(bytes);
        return null;
    }

    const block = routed.realloc(unseal(bytes), header_len + @as(usize, @intCast(len))) catch return null;
    return seal(block);
}

fn size(pointer: ?*anyopaque) callconv(.c) c_int {
    const bytes = pointer orelse return 0;
    return @intCast(unseal(bytes).len - header_len);
}

fn roundUp(len: c_int) callconv(.c) c_int {
    return @intCast(block_alignment.forward(@intCast(len)));
}

fn start(app_data: ?*anyopaque) callconv(.c) c_int {
    _ = app_data;
    return c.SQLITE_OK;
}

fn stop(app_data: ?*anyopaque) callconv(.c) void {
    _ = app_data;
}

fn seal(block: Block) *anyopaque {
    std.mem.writeInt(u64, block[0..header_len], block.len, .little);
    return block[header_len..].ptr;
}

fn unseal(pointer: *anyopaque) Block {
    const bytes: [*]align(block_alignment.toByteUnits()) u8 = @ptrCast(@alignCast(pointer));
    const base = bytes - header_len;
    const len = std.mem.readInt(u64, base[0..header_len], .little);
    return base[0..@intCast(len)];
}

test "SQLite runs on a routed allocator and returns every block to it" {
    var original: c.sqlite3_mem_methods = undefined;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_shutdown());
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_config(c.SQLITE_CONFIG_GETMALLOC, &original));
    defer _ = c.sqlite3_config(c.SQLITE_CONFIG_MALLOC, &original);

    var counting: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    try routeMemory(counting.allocator());
    defer _ = c.sqlite3_shutdown();

    var db: ?*c.sqlite3 = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(":memory:", &db));
    const opened = db.?;
    const sql =
        \\CREATE TABLE commands (text TEXT);
        \\WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2000)
        \\INSERT INTO commands SELECT printf('cargo build --release %d', i) FROM n;
        \\UPDATE commands SET text = text || text;
    ;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(opened, sql, null, null, null));
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_close(opened));
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_shutdown());

    try std.testing.expect(counting.allocations > 0);
    try std.testing.expectEqual(counting.allocations, counting.deallocations);
    try std.testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);
}
