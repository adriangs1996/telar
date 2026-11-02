const std = @import("std");
const State = @import("model/state/ClipboardCaptureState.zig");
const data = @import("model/model.zig");
extern "c" fn putchar(c_int) c_int;

const Operation = enum(u64) { reserve, finish_random, cancel_random, finish_current, cancel_current, restart, reserve_invalid };
const Outcome = enum(u64) { none, reserved, busy, finished, stale, cancelled, unchanged, invalid, exhausted };
const Shift = enum(u6) { first = 13, second = 7, third = 17, pane = 8, generation = 16, completion = 32 };
const seed: u64 = 0x9e3779b97f4a7c15;
const operation_count: u64 = 7;
const operation_limit: u64 = 65536;
const pane_domain: u64 = 5;
const generation_domain: u64 = 5;
const completion_domain: u64 = 17;

fn randomWord(state: *u64) u64 {
    state.* ^= state.* << @intFromEnum(Shift.first);
    state.* ^= state.* >> @intFromEnum(Shift.second);
    state.* ^= state.* << @intFromEnum(Shift.third);

    return state.*;
}

fn write(value: u64) !void {
    for (0..@sizeOf(u64)) |index| {
        const shift: u6 = @intCast(index * @bitSizeOf(u8));
        if (putchar(@intCast((value >> shift) & std.math.maxInt(u8))) < 0) {
            return error.WriteFailed;
        }
    }
}

pub fn main() !void {
    var state: State = .{};
    var random = seed;
    for (0..operation_limit) |index| {
        const word = randomWord(&random);
        const operation: Operation = @enumFromInt(word % operation_count);
        var target: data.AttachmentTarget = .{ .pane_id = @enumFromInt((word >> @intFromEnum(Shift.pane)) % pane_domain), .pane_generation = (word >> @intFromEnum(Shift.generation)) % generation_domain };
        var id = (word >> @intFromEnum(Shift.completion)) % completion_domain;
        var outcome: Outcome = .none;
        var result: ?data.ClipboardCapture = null;
        switch (operation) {
            .reserve, .reserve_invalid => {
                if (operation == .reserve_invalid) {
                    target = .{ .pane_id = .invalid, .pane_generation = 0 };
                }
                result = state.reserve(target) catch |err| failed: {
                    outcome = switch (err) {
                        error.InvalidAttachmentTarget => .invalid,
                        error.ClipboardCaptureIdExhausted => .exhausted,
                    };
                    break :failed null;
                };
                if (outcome == .none) {
                    outcome = if (result != null) .reserved else .busy;
                }
            },
            .finish_random, .finish_current => {
                if (operation == .finish_current) {
                    id = if (state.capture) |capture| @intFromEnum(capture.id) else 0;
                }
                result = state.finish(@enumFromInt(id));
                outcome = if (result != null) .finished else .stale;
            },
            .cancel_random, .cancel_current => {
                if (operation == .cancel_current) {
                    target = if (state.capture) |capture| capture.target else .{ .pane_id = .invalid, .pane_generation = 0 };
                }
                outcome = if (state.cancel(target)) .cancelled else .unchanged;
            },
            .restart => {
                id = if (word & 1 != 0) std.math.maxInt(u64) else 1;
                state = .{ .next_id = id };
            },
        }

        const empty: data.ClipboardCapture = .{ .id = .none, .target = .{ .pane_id = .invalid, .pane_generation = 0 } };
        const returned = result orelse empty;
        const current = state.capture orelse empty;
        for ([_]u64{ index, @intFromEnum(operation), @intFromEnum(target.pane_id), target.pane_generation, id, @intFromEnum(outcome), @intFromEnum(returned.id), @intFromEnum(returned.target.pane_id), returned.target.pane_generation, @intFromEnum(current.id), @intFromEnum(current.target.pane_id), current.target.pane_generation, state.next_id }) |value| {
            try write(value);
        }
    }
}
