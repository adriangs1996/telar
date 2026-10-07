//! Routes SQLite's allocations through a Zig allocator instead of libc's
//! `malloc`. SQLite frees and sizes a block by its pointer alone, so its
//! blocks come from `cblocks`, which keeps each block's length beside it.
const std = @import("std");
const cblocks = @import("cblocks");
const c = @import("c.zig").c;

/// Set only once SQLite accepted the hooks below, so a refused call never
/// sends blocks SQLite already holds to another allocator.
var routed: ?std.mem.Allocator = null;

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
/// `allocator`, which must be thread-safe and outlive SQLite. Call it once,
/// before the process opens any database; SQLite refuses it once initialized
/// and the previous allocator stays.
///
/// ```zig
/// try sqlite.routeMemory(slabheap.allocator);
/// ```
pub fn routeMemory(allocator: std.mem.Allocator) !void {
    // SQLite calls none of the hooks before it initializes, which a
    // successful sqlite3_config means it has not done yet.
    if (c.sqlite3_config(c.SQLITE_CONFIG_MALLOC, &methods) != c.SQLITE_OK) {
        return error.SqliteAlreadyInitialized;
    }

    routed = allocator;
}

fn allocate(len: c_int) callconv(.c) ?*anyopaque {
    if (len <= 0) {
        return null;
    }

    return cblocks.alloc(routed.?, @intCast(len));
}

fn release(pointer: ?*anyopaque) callconv(.c) void {
    cblocks.free(routed.?, pointer);
}

fn reallocate(pointer: ?*anyopaque, len: c_int) callconv(.c) ?*anyopaque {
    return cblocks.realloc(routed.?, pointer, @intCast(@max(len, 0)));
}

fn size(pointer: ?*anyopaque) callconv(.c) c_int {
    const block = pointer orelse return 0;
    return @intCast(cblocks.len(block));
}

fn roundUp(len: c_int) callconv(.c) c_int {
    return @intCast(cblocks.roundUp(@intCast(@max(len, 0))));
}

fn start(app_data: ?*anyopaque) callconv(.c) c_int {
    _ = app_data;
    return c.SQLITE_OK;
}

fn stop(app_data: ?*anyopaque) callconv(.c) void {
    _ = app_data;
}
