//! Quota-accounted Lua VM used by one client configuration generation.

const std = @import("std");
const lua = @import("lua-api").c;
const config_model = @import("model.zig");

const Io = std.Io;

pub const default_callback_instruction_limit: u64 = 100_000;
pub const default_callback_deadline_ns: u64 = 10 * std.time.ns_per_ms;
pub const hook_instruction_interval: u32 = 1_000;

pub const Meter = struct {
    used: usize = 0,
    limit: usize = config_model.default_memory_limit,
};

pub const Execution = struct {
    source: []const u8,
    name: [*:0]const u8,
    results: c_int,
};

/// Owns the Lua allocator and execution budgets for one configuration.
///
/// ```zig
/// const vm = try Vm.init(io, .{});
/// defer vm.deinit();
/// try vm.evaluate("return {}", "@config.lua");
/// ```
pub const Vm = struct {
    io: Io,
    state: *lua.lua_State,
    meter: Meter,
    instruction_count: u64 = 0,
    instruction_limit: u64 = config_model.default_load_instruction_limit,
    deadline_ns: u64 = 0,

    pub fn init(io: Io, limits: config_model.Limits) !*Vm {
        const vm = std.heap.c_allocator.create(Vm) catch return error.OutOfMemory;
        errdefer std.heap.c_allocator.destroy(vm);
        vm.* = .{
            .io = io,
            .state = undefined,
            .meter = .{ .limit = limits.memory },
            .instruction_limit = limits.instructions,
            .deadline_ns = monotonic(io) +| limits.deadline_after_ns,
        };
        vm.state = lua.lua_newstate(allocate, vm, 0) orelse return error.OutOfMemory;
        lua.lua_sethook(vm.state, instructionHook, lua.LUA_MASKCOUNT, hook_instruction_interval);
        return vm;
    }

    pub fn deinit(vm: *Vm) void {
        lua.lua_close(vm.state);
        std.debug.assert(vm.meter.used == 0);
        std.heap.c_allocator.destroy(vm);
    }

    pub fn resetBudget(vm: *Vm, instructions: u64, deadline_after_ns: u64) void {
        vm.instruction_count = 0;
        vm.instruction_limit = instructions;
        vm.deadline_ns = monotonic(vm.io) +| deadline_after_ns;
    }

    pub fn evaluate(vm: *Vm, source: []const u8, name: [*:0]const u8) !void {
        return vm.execute(.{ .source = source, .name = name, .results = 1 });
    }

    pub fn execute(vm: *Vm, execution: Execution) !void {
        if (lua.luaL_loadbufferx(vm.state, execution.source.ptr, execution.source.len, execution.name, "t") != lua.LUA_OK) {
            return error.LuaLoadFailed;
        }

        if (lua.lua_pcallk(vm.state, 0, execution.results, 0, 0, null) != lua.LUA_OK) {
            return error.LuaRuntimeFailed;
        }
    }

    pub fn errorMessage(vm: *Vm) []const u8 {
        var len: usize = 0;
        const message = lua.lua_tolstring(vm.state, -1, &len) orelse return "unknown Lua error";
        return message[0..len];
    }

    fn allocate(userdata: ?*anyopaque, pointer: ?*anyopaque, old_size: usize, new_size: usize) callconv(.c) ?*anyopaque {
        const vm: *Vm = @ptrCast(@alignCast(userdata.?));
        if (new_size == 0) {
            std.c.free(pointer);
            vm.meter.used -|= old_size;
            return null;
        }

        const without_old = vm.meter.used -| old_size;
        const next = std.math.add(usize, without_old, new_size) catch return null;
        if (next > vm.meter.limit) {
            return null;
        }

        const result = if (pointer) |existing| std.c.realloc(existing, new_size) else std.c.malloc(new_size);
        if (result != null) {
            vm.meter.used = next;
        }

        return result;
    }

    fn instructionHook(state: ?*lua.lua_State, _: ?*lua.lua_Debug) callconv(.c) void {
        var userdata: ?*anyopaque = null;
        _ = lua.lua_getallocf(state.?, &userdata);
        const vm: *Vm = @ptrCast(@alignCast(userdata.?));
        vm.instruction_count +|= hook_instruction_interval;
        if (vm.instruction_count <= vm.instruction_limit and monotonic(vm.io) <= vm.deadline_ns) {
            return;
        }

        _ = lua.lua_pushstring(state.?, "Telar Lua execution budget exceeded");
        _ = lua.lua_error(state.?);
    }
};

fn monotonic(io: Io) u64 {
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
