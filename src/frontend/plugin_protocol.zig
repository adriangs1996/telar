//! Bounded one-shot protocol from a plugin worker back to the client broker.

const std = @import("std");
const action_mod = @import("action.zig");
const lua_config = @import("lua_config.zig");

pub const max_bytes = 1 + lua_config.max_callback_effects * 3;

pub fn encode(buffer: []u8, batch: *const lua_config.EffectBatch) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.writeByte(batch.len);
    for (batch.slice()) |action| switch (action) {
        .split_pane => |value| {
            try writer.writeByte(1);
            try writer.writeByte(@intFromEnum(value));
        },
        .focus_pane => |value| {
            try writer.writeByte(2);
            try writer.writeByte(@intFromEnum(value));
        },
        .resize_pane => |value| {
            try writer.writeByte(12);
            try writer.writeByte(@intFromEnum(value));
        },
        .toggle_pane_fullscreen => try writer.writeByte(13),
        .toggle_sidebar => try writer.writeByte(3),
        .close_pane => try writer.writeByte(4),
        .new_tab => try writer.writeByte(5),
        .select_tab_offset => |value| {
            try writer.writeByte(6);
            try writer.writeByte(@bitCast(value));
        },
        .select_tab => |value| {
            try writer.writeByte(7);
            try writer.writeByte(value);
        },
        .rename_tab => try writer.writeByte(8),
        .close_tab => try writer.writeByte(9),
        .move_tab => |value| {
            try writer.writeByte(10);
            try writer.writeByte(@intFromEnum(value));
        },
        .detach => try writer.writeByte(11),
        .toggle_workspace_list => try writer.writeByte(14),
        .new_workspace => try writer.writeByte(15),
        .rename_workspace => try writer.writeByte(16),
        .select_workspace => |value| {
            try writer.writeByte(17);
            try writer.writeByte(value);
        },
        .enter_copy_mode => return error.InvalidWorkerEffect,
        .lua_callback, .lua_expr, .plugin => return error.InvalidWorkerEffect,
    };
    return writer.buffered();
}

pub fn decode(bytes: []const u8) !lua_config.EffectBatch {
    if (bytes.len == 0) return error.TruncatedWorkerResult;
    const count = bytes[0];
    if (count > lua_config.max_callback_effects) return error.TooManyWorkerEffects;
    var batch: lua_config.EffectBatch = .{};
    var offset: usize = 1;
    for (0..count) |index| {
        if (offset >= bytes.len) return error.TruncatedWorkerResult;
        const tag = bytes[offset];
        offset += 1;
        batch.items[index] = switch (tag) {
            1 => .{ .split_pane = std.enums.fromInt(
                action_mod.SplitDirection,
                try byte(bytes, &offset),
            ) orelse return error.InvalidWorkerEffect },
            2 => .{ .focus_pane = std.enums.fromInt(
                action_mod.Direction,
                try byte(bytes, &offset),
            ) orelse return error.InvalidWorkerEffect },
            3 => .toggle_sidebar,
            4 => .close_pane,
            5 => .new_tab,
            6 => .{ .select_tab_offset = @bitCast(try byte(bytes, &offset)) },
            7 => .{ .select_tab = try byte(bytes, &offset) },
            8 => .rename_tab,
            9 => .close_tab,
            10 => .{ .move_tab = std.enums.fromInt(
                action_mod.TabMove,
                try byte(bytes, &offset),
            ) orelse return error.InvalidWorkerEffect },
            11 => .detach,
            12 => .{ .resize_pane = std.enums.fromInt(
                action_mod.Direction,
                try byte(bytes, &offset),
            ) orelse return error.InvalidWorkerEffect },
            13 => .toggle_pane_fullscreen,
            14 => .toggle_workspace_list,
            15 => .new_workspace,
            16 => .rename_workspace,
            17 => .{ .select_workspace = try byte(bytes, &offset) },
            else => return error.UnknownWorkerEffect,
        };
    }
    if (offset != bytes.len) return error.TrailingWorkerResult;
    batch.len = count;
    return batch;
}

fn byte(bytes: []const u8, offset: *usize) !u8 {
    if (offset.* >= bytes.len) return error.TruncatedWorkerResult;
    defer offset.* += 1;
    return bytes[offset.*];
}

test "plugin result protocol round trips semantic effects" {
    var batch: lua_config.EffectBatch = .{};
    batch.items[0] = .{ .focus_pane = .left };
    batch.items[1] = .{ .select_tab_offset = -1 };
    batch.items[2] = .{ .resize_pane = .down };
    batch.items[3] = .toggle_pane_fullscreen;
    batch.items[4] = .toggle_sidebar;
    batch.items[5] = .new_workspace;
    batch.items[6] = .{ .select_workspace = 3 };
    batch.len = 7;
    var buffer: [max_bytes]u8 = undefined;
    try std.testing.expectEqualDeep(batch, try decode(try encode(&buffer, &batch)));
}

test "plugin result protocol rejects invalid enum discriminants" {
    try std.testing.expectError(error.InvalidWorkerEffect, decode(&.{ 1, 1, 255 }));
}
