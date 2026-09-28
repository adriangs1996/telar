const std = @import("std");
const cblocks = @import("cblocks");
const lua_api = @import("lua-api");
const Meter = @import("Meter.zig");
const Limits = @import("Limits.zig");
const vm_support = @import("vm_support.zig");
const Execution = @import("Execution.zig");
/// Owns the Lua allocator and execution budgets for one isolated VM.
///
/// ```zig
/// const vm = try Vm.init(io, gpa, .{});
/// defer vm.deinit();
/// try vm.evaluate("return {}", "@config.lua");
/// ```
const Vm = @This();

io: std.Io,
/// What the VM, its Lua heap and `json.decode` allocate from.
gpa: std.mem.Allocator,
state: *lua_api.c.lua_State,
meter: Meter,
instruction_count: u64 = 0,
instruction_limit: u64,
deadline_ns: u64,

pub fn init(io: std.Io, gpa: std.mem.Allocator, limits: Limits) !*Vm {
    const owned = gpa.create(Vm) catch return error.OutOfMemory;
    errdefer gpa.destroy(owned);
    owned.* = .{
        .io = io,
        .gpa = gpa,
        .state = undefined,
        .meter = .{ .limit = limits.memory },
        .instruction_limit = limits.instructions,
        .deadline_ns = vm_support.monotonic(io) +| limits.deadline_after_ns,
    };
    owned.state = lua_api.c.lua_newstate(allocate, owned, 0) orelse return error.OutOfMemory;
    lua_api.c.lua_sethook(owned.state, instructionHook, lua_api.c.LUA_MASKCOUNT, vm_support.hook_instruction_interval);
    return owned;
}

pub fn deinit(self: *Vm) void {
    lua_api.c.lua_close(self.state);
    std.debug.assert(self.meter.used == 0);
    self.gpa.destroy(self);
}

pub fn resetBudget(self: *Vm, instructions: u64, deadline_after_ns: u64) void {
    self.instruction_count = 0;
    self.instruction_limit = instructions;
    self.deadline_ns = vm_support.monotonic(self.io) +| deadline_after_ns;
}

pub fn evaluate(self: *Vm, source: []const u8, name: [*:0]const u8) !void {
    return self.execute(.{ .source = source, .name = name, .results = 1 });
}

pub fn execute(self: *Vm, execution: Execution) !void {
    if (lua_api.c.luaL_loadbufferx(self.state, execution.source.ptr, execution.source.len, execution.name, "t") != lua_api.c.LUA_OK) {
        return error.LuaLoadFailed;
    }

    if (lua_api.c.lua_pcallk(self.state, 0, execution.results, 0, 0, null) != lua_api.c.LUA_OK) {
        return error.LuaRuntimeFailed;
    }
}

pub fn errorMessage(self: *Vm) []const u8 {
    var len: usize = 0;
    const message = lua_api.c.lua_tolstring(self.state, -1, &len) orelse return "unknown Lua error";
    return message[0..len];
}

/// The VM that owns `state`, from the userdata of its allocator.
///
/// ```zig
/// const gpa = Vm.of(state).gpa;
/// ```
pub fn of(state: *lua_api.c.lua_State) *Vm {
    var userdata: ?*anyopaque = null;
    _ = lua_api.c.lua_getallocf(state, &userdata);
    return @ptrCast(@alignCast(userdata.?));
}

// Lua fixes this four-parameter allocator signature as part of its C ABI.
// Blocks come from `cblocks`, which remembers each block's real length, so a
// shrink that cannot move keeps the old block: Lua requires shrinking never
// to fail.
// codestyle: allow(maximum-parameter-count)
fn allocate(userdata: ?*anyopaque, pointer: ?*anyopaque, old_size: usize, new_size: usize) callconv(.c) ?*anyopaque {
    const vm: *Vm = @ptrCast(@alignCast(userdata.?));
    if (new_size == 0) {
        if (pointer) |existing| {
            cblocks.free(vm.gpa, existing);
            vm.meter.used -|= old_size;
        }

        return null;
    }

    const without_old = vm.meter.used -| old_size;
    const next = std.math.add(usize, without_old, new_size) catch return null;
    if (next > vm.meter.limit) {
        return null;
    }

    const result = cblocks.realloc(vm.gpa, pointer, new_size) orelse shrunk: {
        const existing = pointer orelse return null;
        if (new_size > old_size) {
            return null;
        }

        break :shrunk existing;
    };
    vm.meter.used = next;
    return result;
}

fn instructionHook(state: ?*lua_api.c.lua_State, _: ?*lua_api.c.lua_Debug) callconv(.c) void {
    const vm = of(state.?);
    vm.instruction_count +|= vm_support.hook_instruction_interval;
    if (vm.instruction_count <= vm.instruction_limit and vm_support.monotonic(vm.io) <= vm.deadline_ns) {
        return;
    }

    _ = lua_api.c.lua_pushstring(state.?, "Telar Lua execution budget exceeded");
    _ = lua_api.c.lua_error(state.?);
}
