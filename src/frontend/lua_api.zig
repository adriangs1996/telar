//! Narrow C import for the vendored Lua runtime.

pub const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

test "vendored Lua version is pinned" {
    const std = @import("std");
    try std.testing.expectEqual(@as(c_int, 505), c.LUA_VERSION_NUM);
    try std.testing.expectEqualStrings("Lua 5.5", std.mem.span(c.LUA_VERSION));
}
