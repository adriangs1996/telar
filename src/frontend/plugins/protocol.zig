//! Bounded one-shot protocol from a plugin worker back to the client broker.

const std = @import("std");
const action_mod = @import("../input/root.zig").action;
const lua_config = @import("../config/root.zig");
const core = @import("telar-core");

const schema = core.schema;
const notification_max_bytes = 1 + 1 + 4 + 1 + 8 + 1 +
    schema.max_notification_title_bytes + 1 + schema.max_notification_message_bytes;
pub const max_bytes = 1 + lua_config.max_callback_effects * notification_max_bytes;

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
        .navigate_pane => return error.InvalidWorkerEffect,
        .resize_pane => |value| {
            try writer.writeByte(12);
            try writer.writeByte(@intFromEnum(value));
        },
        .toggle_pane_fullscreen => try writer.writeByte(13),
        .toggle_sidebar => try writer.writeByte(3),
        .resize_sidebar => |value| {
            try writer.writeByte(19);
            try writer.writeByte(@intFromEnum(value));
        },
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
        .enter_copy_mode, .command_tab, .goto_picker, .history_palette, .suggest_command => return error.InvalidWorkerEffect,
        .notification => |*value| {
            try writer.writeByte(18);
            try writer.writeByte(@intFromEnum(value.level));
            try writeU32(&writer, value.duration_ms);
            switch (value.target) {
                .none => try writer.writeByte(0),
                .pane => |pane_id| {
                    try writer.writeByte(1);
                    try writeU64(&writer, schema.id.raw(pane_id));
                },
                .tab => |tab_id| {
                    try writer.writeByte(2);
                    try writeU64(&writer, schema.id.raw(tab_id));
                },
                .workspace => |workspace_id| {
                    try writer.writeByte(3);
                    try writeU64(&writer, schema.id.raw(workspace_id));
                },
            }
            try writeSized8(&writer, value.title());
            try writeSized8(&writer, value.message());
        },
        .lua_callback, .lua_expr, .plugin => return error.InvalidWorkerEffect,
    };
    return writer.buffered();
}

pub fn decode(bytes: []const u8) !lua_config.EffectBatch {
    if (bytes.len == 0) {
        return error.TruncatedWorkerResult;
    }
    const count = bytes[0];
    if (count > lua_config.max_callback_effects) {
        return error.TooManyWorkerEffects;
    }
    var batch: lua_config.EffectBatch = .{};
    var offset: usize = 1;
    for (0..count) |index| {
        if (offset >= bytes.len) {
            return error.TruncatedWorkerResult;
        }
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
            18 => notification: {
                const level = std.enums.fromInt(
                    schema.NotificationLevel,
                    try byte(bytes, &offset),
                ) orelse return error.InvalidWorkerEffect;
                const duration_ms = try readU32(bytes, &offset);
                const target: schema.NotificationTarget = switch (try byte(bytes, &offset)) {
                    0 => .none,
                    1 => .{ .pane = schema.id.pane(try readU64(bytes, &offset)) catch
                        return error.InvalidWorkerEffect },
                    2 => .{ .tab = schema.id.tab(try readU64(bytes, &offset)) catch
                        return error.InvalidWorkerEffect },
                    3 => .{ .workspace = schema.id.workspace(try readU64(bytes, &offset)) catch
                        return error.InvalidWorkerEffect },
                    else => return error.InvalidWorkerEffect,
                };
                const title = try sized8(bytes, &offset);
                const message = try sized8(bytes, &offset);
                break :notification .{ .notification = action_mod.Notification.init(
                    level,
                    duration_ms,
                    target,
                    title,
                    message,
                ) catch return error.InvalidWorkerEffect };
            },
            19 => .{ .resize_sidebar = std.enums.fromInt(
                action_mod.SidebarDirection,
                try byte(bytes, &offset),
            ) orelse return error.InvalidWorkerEffect },
            else => return error.UnknownWorkerEffect,
        };
    }
    if (offset != bytes.len) {
        return error.TrailingWorkerResult;
    }
    batch.len = count;
    return batch;
}

fn writeU32(writer: *std.Io.Writer, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try writer.writeAll(&bytes);
}

fn writeU64(writer: *std.Io.Writer, value: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    try writer.writeAll(&bytes);
}

fn writeSized8(writer: *std.Io.Writer, bytes: []const u8) !void {
    if (bytes.len > std.math.maxInt(u8)) {
        return error.InvalidWorkerEffect;
    }
    try writer.writeByte(@intCast(bytes.len));
    try writer.writeAll(bytes);
}

fn readU32(bytes: []const u8, offset: *usize) !u32 {
    if (bytes.len -| offset.* < 4) {
        return error.TruncatedWorkerResult;
    }
    defer offset.* += 4;
    return std.mem.readInt(u32, bytes[offset.*..][0..4], .little);
}

fn readU64(bytes: []const u8, offset: *usize) !u64 {
    if (bytes.len -| offset.* < 8) {
        return error.TruncatedWorkerResult;
    }
    defer offset.* += 8;
    return std.mem.readInt(u64, bytes[offset.*..][0..8], .little);
}

fn sized8(bytes: []const u8, offset: *usize) ![]const u8 {
    const len = try byte(bytes, offset);
    if (bytes.len -| offset.* < len) {
        return error.TruncatedWorkerResult;
    }
    defer offset.* += len;
    return bytes[offset.*..][0..len];
}

fn byte(bytes: []const u8, offset: *usize) !u8 {
    if (offset.* >= bytes.len) {
        return error.TruncatedWorkerResult;
    }
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
    batch.items[5] = .{ .resize_sidebar = .right };
    batch.items[6] = .new_workspace;
    batch.items[7] = .{ .select_workspace = 3 };
    batch.items[8] = .{ .notification = try action_mod.Notification.init(
        .warning,
        3000,
        .{ .workspace = @enumFromInt(9) },
        "Agent waiting",
        "Review its question",
    ) };
    batch.len = 9;
    var buffer: [max_bytes]u8 = undefined;
    try std.testing.expectEqualDeep(batch, try decode(try encode(&buffer, &batch)));
}

test "plugin result protocol rejects invalid enum discriminants" {
    try std.testing.expectError(error.InvalidWorkerEffect, decode(&.{ 1, 1, 255 }));
}
