//! Durable session checkpoint records and their file encoding.
//!
//! The record types are deliberately separate from live aggregates and from
//! client projections (ADR 0005). A checkpoint holds only what a restart can
//! rebuild: identities, paths, labels, pane launch commands and client layout
//! replicas. File descriptors, PTYs and in-flight work are never written.

const std = @import("std");
const core = @import("telar-core");

pub const schema = core.schema;
pub const wire = core.schema.wire;

pub const magic: *const [8]u8 = "TELARCKP";
/// Version 2 added the agent title to pane records; version 1 files still read.
pub const version: u16 = 2;
pub const oldest_readable_version: u16 = 1;
pub const max_file_bytes = 4 * 1024 * 1024;
pub const max_launch_arguments = 32;
pub const max_launch_bytes = 1024;

pub const Counters = @import("Counters.zig");

pub const WorkspaceRecord = @import("WorkspaceRecord.zig");

pub const TabRecord = @import("TabRecord.zig");

pub const PaneRecord = @import("PaneRecord.zig");

pub const LayoutRecord = @import("LayoutRecord.zig");

pub const Record = union(enum) {
    workspace: WorkspaceRecord,
    tab: TabRecord,
    pane: PaneRecord,
    layout: LayoutRecord,
};

pub const Kind = enum(u8) {
    end = 0,
    workspace = 1,
    tab = 2,
    pane = 3,
    layout = 4,
};

pub const Encoder = @import("Encoder.zig");

pub const Reader = @import("Reader.zig");

pub const ArgumentIterator = @import("ArgumentIterator.zig");

/// An empty title carries no source. A present one must be printable and
/// come from a durable source, so restore never revives a placeholder.
pub fn validateTitle(title: []const u8, source: u8) !void {
    if (title.len == 0) {
        if (source != 0) {
            return error.InvalidCheckpoint;
        }

        return;
    }

    schema.validateSessionTitle(title) catch return error.InvalidCheckpoint;
    switch (std.enums.fromInt(schema.AgentTitleSource, source) orelse return error.InvalidCheckpoint) {
        .generated, .manual, .agent => {},
        .telar, .terminal => return error.InvalidCheckpoint,
    }
}

pub fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path.len > schema.max_cwd_bytes or std.mem.indexOfScalar(u8, path, 0) != null) {
        return error.InvalidCheckpoint;
    }
}

test "checkpoint records round trip through the file encoding" {
    var buffer: [4096]u8 = undefined;
    var encoder = try Encoder.init(&buffer, .{
        .next_workspace_id = 3,
        .next_tab_id = 5,
        .next_pane_id = 9,
        .next_pane_generation = 12,
    });
    try encoder.workspace(.{ .id = 1, .path = "/work/telar", .name = "", .first_tab_id = 1, .first_tab_label = "main" });
    try encoder.workspace(.{ .id = 2, .path = "/work/api", .name = "backend", .first_tab_id = 2, .first_tab_label = "editor" });
    try encoder.tab(.{ .workspace_id = 1, .tab_id = 4, .label = "logs" });
    try encoder.pane(.{
        .pane_id = 7,
        .workspace_id = 1,
        .tab_id = 4,
        .cwd = "/work/telar/src",
        .cols = 120,
        .rows = 40,
        .arguments = "/bin/zsh\x00-l\x00",
        .argument_count = 2,
        .agent_provider = 1,
        .agent_session = "0192aaaa-bbbb-cccc-dddd-eeeeffff0000",
        .agent_title = "Investigate proxy lifecycle",
        .agent_title_source = @intFromEnum(schema.AgentTitleSource.generated),
    });
    try encoder.layout(.{ .identity = 42, .last_used = 3, .payload = "\x1a\x01" });
    const bytes = try encoder.finish();

    var reader = try Reader.init(bytes);
    try std.testing.expectEqual(@as(u64, 12), reader.counters.next_pane_generation);
    const first = (try reader.next()).?.workspace;
    try std.testing.expectEqualStrings("/work/telar", first.path);
    const second = (try reader.next()).?.workspace;
    try std.testing.expectEqualStrings("backend", second.name);
    try std.testing.expectEqualStrings("editor", second.first_tab_label);
    const logs = (try reader.next()).?.tab;
    try std.testing.expectEqualStrings("logs", logs.label);
    const pane = (try reader.next()).?.pane;
    try std.testing.expectEqual(@as(u64, 7), pane.pane_id);
    var arguments = ArgumentIterator.init(pane.arguments);
    try std.testing.expectEqualStrings("/bin/zsh", arguments.next().?);
    try std.testing.expectEqualStrings("-l", arguments.next().?);
    try std.testing.expect(arguments.next() == null);
    try std.testing.expectEqual(@as(u8, 1), pane.agent_provider);
    try std.testing.expectEqualStrings("0192aaaa-bbbb-cccc-dddd-eeeeffff0000", pane.agent_session);
    try std.testing.expectEqualStrings("Investigate proxy lifecycle", pane.agent_title);
    try std.testing.expectEqual(@intFromEnum(schema.AgentTitleSource.generated), pane.agent_title_source);
    const layout = (try reader.next()).?.layout;
    try std.testing.expectEqual(@as(u64, 42), layout.identity);
    try std.testing.expectEqualStrings("\x1a\x01", layout.payload);
    try std.testing.expect(try reader.next() == null);
}

test "pane titles must be printable and come from a durable source" {
    var buffer: [512]u8 = undefined;
    const base: PaneRecord = .{
        .pane_id = 7,
        .workspace_id = 1,
        .tab_id = 4,
        .cwd = "/work",
        .cols = 80,
        .rows = 24,
        .arguments = "/bin/zsh\x00",
        .argument_count = 1,
        .agent_provider = 1,
        .agent_session = "0192aaaa-bbbb-cccc-dddd-eeeeffff0000",
    };
    const counters: Counters = .{ .next_workspace_id = 1, .next_tab_id = 1, .next_pane_id = 1, .next_pane_generation = 1 };

    var placeholder = base;
    placeholder.agent_title = "New Claude Code session";
    placeholder.agent_title_source = @intFromEnum(schema.AgentTitleSource.telar);
    var encoder = try Encoder.init(&buffer, counters);
    try std.testing.expectError(error.InvalidCheckpoint, encoder.pane(placeholder));

    var agent_named = base;
    agent_named.agent_title = "Fix proxy";
    agent_named.agent_title_source = @intFromEnum(schema.AgentTitleSource.agent);
    encoder = try Encoder.init(&buffer, counters);
    try encoder.pane(agent_named);

    var control = base;
    control.agent_title = "a\x1bb";
    control.agent_title_source = @intFromEnum(schema.AgentTitleSource.manual);
    encoder = try Encoder.init(&buffer, counters);
    try std.testing.expectError(error.InvalidCheckpoint, encoder.pane(control));

    var sourced_empty = base;
    sourced_empty.agent_title_source = @intFromEnum(schema.AgentTitleSource.generated);
    encoder = try Encoder.init(&buffer, counters);
    try std.testing.expectError(error.InvalidCheckpoint, encoder.pane(sourced_empty));

    encoder = try Encoder.init(&buffer, counters);
    try encoder.pane(base);
    var reader = try Reader.init(try encoder.finish());
    const pane = (try reader.next()).?.pane;
    try std.testing.expectEqualStrings("", pane.agent_title);
}

test "a version 1 checkpoint still reads, with no pane title" {
    var buffer: [512]u8 = undefined;
    var inner = wire.Encoder.init(&buffer);
    try inner.writeBytes(magic);
    try inner.writeInt(u16, 1);
    try inner.writeInt(u64, 2);
    try inner.writeInt(u64, 3);
    try inner.writeInt(u64, 4);
    try inner.writeInt(u64, 5);
    try inner.writeByte(3);
    try inner.writeInt(u64, 7);
    try inner.writeInt(u64, 1);
    try inner.writeInt(u64, 1);
    try inner.writeSized16("/work");
    try inner.writeInt(u16, 80);
    try inner.writeInt(u16, 24);
    try inner.writeInt(u16, 1);
    try inner.writeSized16("/bin/zsh\x00");
    try inner.writeByte(1);
    try inner.writeSized16("0192aaaa-bbbb-cccc-dddd-eeeeffff0000");
    try inner.writeByte(0);
    const bytes = inner.finish();

    var reader = try Reader.init(bytes);
    try std.testing.expectEqual(@as(u16, 1), reader.version);
    const pane = (try reader.next()).?.pane;
    try std.testing.expectEqualStrings("0192aaaa-bbbb-cccc-dddd-eeeeffff0000", pane.agent_session);
    try std.testing.expectEqualStrings("", pane.agent_title);
    try std.testing.expect(try reader.next() == null);
}

test "corrupt, truncated and foreign checkpoints are rejected" {
    var buffer: [256]u8 = undefined;
    var encoder = try Encoder.init(&buffer, .{ .next_workspace_id = 1, .next_tab_id = 1, .next_pane_id = 1, .next_pane_generation = 1 });
    try encoder.tab(.{ .workspace_id = 1, .tab_id = 1, .label = "main" });
    const bytes = try encoder.finish();

    try std.testing.expectError(error.InvalidCheckpoint, Reader.init("TELARXXX\x01\x00"));
    var truncated = try Reader.init(bytes[0 .. bytes.len - 3]);
    try std.testing.expectError(error.Truncated, truncated.next());
    var flipped: [256]u8 = undefined;
    @memcpy(flipped[0..bytes.len], bytes);
    flipped[magic.len] = 0x7f;
    try std.testing.expectError(error.UnsupportedCheckpointVersion, Reader.init(flipped[0..bytes.len]));
}
