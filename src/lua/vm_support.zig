//! Quota-accounted Lua VM shared by isolated Telar workers.

const std = @import("std");
const lua = @import("lua-api").c;

pub const Io = std.Io;

pub const default_memory_limit: usize = 16 * 1024 * 1024;
pub const default_load_instruction_limit: u64 = 1_000_000;
pub const default_load_deadline_ns: u64 = 100 * std.time.ns_per_ms;
pub const default_callback_instruction_limit: u64 = 100_000;
pub const default_callback_deadline_ns: u64 = 10 * std.time.ns_per_ms;
pub const hook_instruction_interval: u32 = 1_000;

pub const Limits = @import("Limits.zig");

pub const Meter = @import("Meter.zig");

pub const Execution = @import("Execution.zig");

pub const Vm = @import("Vm.zig");

pub fn monotonic(io: Io) u64 {
    const timestamp = Io.Timestamp.now(io, .awake);
    return @intCast(@max(timestamp.nanoseconds, 0));
}

test "VM evaluates source under a bounded allocator" {
    var vm = try Vm.init(std.testing.io, .{
        .memory = 1024 * 1024,
        .instructions = 100_000,
        .deadline_after_ns = std.time.ns_per_s,
    });
    defer vm.deinit();

    try vm.evaluate("return 42", "@test.lua");
    try std.testing.expectEqual(@as(lua.lua_Integer, 42), lua.lua_tointegerx(vm.state, -1, null));
}

test "VM interrupts an instruction loop" {
    var vm = try Vm.init(std.testing.io, .{
        .memory = 1024 * 1024,
        .instructions = 10_000,
        .deadline_after_ns = std.time.ns_per_s,
    });
    defer vm.deinit();

    try std.testing.expectError(error.LuaRuntimeFailed, vm.evaluate("while true do end", "@loop.lua"));
    try std.testing.expect(std.mem.indexOf(u8, vm.errorMessage(), "budget exceeded") != null);
}
