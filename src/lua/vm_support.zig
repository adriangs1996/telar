//! Quota-accounted Lua VM shared by isolated Telar workers.

const std = @import("std");
const Vm = @import("Vm.zig");
const lua_api = @import("lua-api");

pub const default_memory_limit: usize = 16 * 1024 * 1024;

// The instruction limit is the budget: it bounds Lua's own work the same way
// on every host, whatever else the machine is running. The wall-clock
// deadline is only a safety net for instructions whose cost the count cannot
// see, such as `string.rep` over megabytes, so it sits far above what a whole
// instruction budget costs: a million allocating instructions take about
// 20 ms in a release build and 170 ms in a debug one. A deadline near that
// cost rejects valid configuration whenever the scheduler delays the thread.
pub const default_load_instruction_limit: u64 = 1_000_000;
pub const default_load_deadline_ns: u64 = 2 * std.time.ns_per_s;
pub const default_callback_instruction_limit: u64 = 100_000;
// Callbacks run on the interactive path, so their net is the longest stall a
// runaway callback may cause: 100 ms, against about 2 ms for its budget.
pub const default_callback_deadline_ns: u64 = 100 * std.time.ns_per_ms;
pub const hook_instruction_interval: u32 = 1_000;

pub fn monotonic(io: std.Io) u64 {
    const timestamp = std.Io.Timestamp.now(io, .awake);
    return @intCast(@max(timestamp.nanoseconds, 0));
}

test "VM evaluates source under a bounded allocator" {
    var vm = try Vm.init(std.testing.io, std.testing.allocator, .{
        .memory = 1024 * 1024,
        .instructions = 100_000,
        .deadline_after_ns = std.time.ns_per_s,
    });
    defer vm.deinit();

    try vm.evaluate("return 42", "@test.lua");
    try std.testing.expectEqual(@as(lua_api.c.lua_Integer, 42), lua_api.c.lua_tointegerx(vm.state, -1, null));
}

test "VM interrupts an instruction loop" {
    var vm = try Vm.init(std.testing.io, std.testing.allocator, .{
        .memory = 1024 * 1024,
        .instructions = 10_000,
        .deadline_after_ns = std.time.ns_per_s,
    });
    defer vm.deinit();

    try std.testing.expectError(error.LuaRuntimeFailed, vm.evaluate("while true do end", "@loop.lua"));
    try std.testing.expect(std.mem.indexOf(u8, vm.errorMessage(), "budget exceeded") != null);
}

test "the meter counts the bytes Lua holds, not the type tags of new blocks" {
    var vm = try Vm.init(std.testing.io, std.testing.allocator, .{
        .memory = 8 * 1024 * 1024,
        .instructions = 10_000_000,
        .deadline_after_ns = 10 * std.time.ns_per_s,
    });
    defer vm.deinit();

    // Every table and string is a new block, for which Lua passes the type
    // tag where the old size would go.
    try vm.evaluate("kept = {} for i = 1, 2000 do kept[i] = { 'k' .. i } end return #kept", "@meter.lua");
    const kib: usize = @intCast(lua_api.c.lua_gc(vm.state, lua_api.c.LUA_GCCOUNT));
    const bytes: usize = @intCast(lua_api.c.lua_gc(vm.state, lua_api.c.LUA_GCCOUNTB));
    try std.testing.expectEqual(kib * 1024 + bytes, vm.meter.used);
}
