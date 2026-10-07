//! Quota-accounted Lua VM shared by isolated Telar workers.

const builtin = @import("builtin");
const std = @import("std");

pub const default_memory_limit: usize = 16 * 1024 * 1024;

// The instruction limit is the budget: it bounds Lua's own work the same way
// on every host, whatever else the machine is running. Pattern matching,
// plain `string.find` and `table.sort` charge their steps to the same count
// (`luaL_chargesteps` in the vendored lauxlib.c), so one backtracking search
// or large sort cannot run unbounded. The count hook is the only place
// either limit is checked, between instructions and between those steps; no
// limit interrupts any other single C call. The memory limit bounds those:
// the costliest, `string.rep` of 15 MiB, takes about 25 ms in a release
// build. The wall-clock deadline is a safety net for instructions
// that are each that costly, so it sits far above what a whole instruction
// budget costs: a million allocating instructions take about 20 ms in a
// release build and 170 ms in a debug one. A deadline near that cost
// rejects valid configuration whenever the scheduler delays the thread.
pub const default_load_instruction_limit: u64 = 1_000_000;
pub const default_load_deadline_ns: u64 = 2 * std.time.ns_per_s;
pub const default_callback_instruction_limit: u64 = 100_000;
// A pick's `items` function runs once, when a person opens the pick, and
// may turn a whole list command's output into thousands of options, so it
// gets ten times a key callback's budget, about 20 ms of work. Bar and
// panel renders run on the loop that routes keys, on every tick, and keep
// a key callback's budget.
pub const default_pick_items_instruction_limit: u64 = 1_000_000;
// A render's net sits above what its budget costs, as the load deadline
// does: 100 ms against at most about 20 ms in a release build. A debug
// build runs Lua about ten times slower, so its net scales with it instead
// of failing renders that are within their budget.
pub const default_render_deadline_ns: u64 = if (builtin.mode == .Debug) debug_slowdown * release_render_deadline_ns else release_render_deadline_ns;
const release_render_deadline_ns: u64 = 100 * std.time.ns_per_ms;
const debug_slowdown = 10;
// Callbacks run on the interactive path, so their net is the longest stall a
// runaway callback may cause: 100 ms, against about 2 ms for its budget.
pub const default_callback_deadline_ns: u64 = 100 * std.time.ns_per_ms;
pub const hook_instruction_interval: u32 = 1_000;

pub fn monotonic(io: std.Io) u64 {
    const timestamp = std.Io.Timestamp.now(io, .awake);
    return @intCast(@max(timestamp.nanoseconds, 0));
}
