//! Durable session checkpoint records and their file encoding.
//!
//! The record types are deliberately separate from live aggregates and from
//! client projections (docs/invariants.md, Ownership). A checkpoint holds only what a restart can
//! rebuild: identities, paths, labels, pane launch commands and client layout
//! replicas. File descriptors, PTYs and in-flight work are never written.

const bytecodec = @import("bytecodec");
const core = @import("telar-core");
const WorkspaceRecord = @import("WorkspaceRecord.zig");
const TabRecord = @import("TabRecord.zig");
const PaneRecord = @import("PaneRecord.zig");
const LayoutRecord = @import("LayoutRecord.zig");
const WorktreeRecord = @import("WorktreeRecord.zig");
const std = @import("std");
const Encoder = @import("Encoder.zig");
const Reader = @import("Reader.zig");
const ArgumentIterator = @import("ArgumentIterator.zig");
const Counters = @import("Counters.zig");

pub const magic: *const [8]u8 = "TELARCKP";
/// Version 2 added pane titles; version 3 permits automatic tab labels.
/// Version 4 added pane kinds for agent panes; version 5 drops them again.
/// Version 6 adds worktree records; version 7 adds the machine that
/// dispatched each worktree; version 8 records whether an agent kept its
/// session in the pane.
/// Older labels remain explicit because their naming intent was not recorded.
pub const version: u16 = 8;
pub const oldest_readable_version: u16 = 1;
/// The first version whose worktree records end with `dispatched_from`.
pub const dispatched_from_version: u16 = 7;
/// The first version whose pane records end with `agent_in_pane`.
pub const agent_in_pane_version: u16 = 8;
pub const max_file_bytes = 4 * 1024 * 1024;
pub const max_launch_arguments = 32;
pub const max_launch_bytes = 1024;

pub const Record = union(enum) {
    workspace: WorkspaceRecord,
    tab: TabRecord,
    pane: PaneRecord,
    layout: LayoutRecord,
    worktree: WorktreeRecord,
};

/// The only version whose pane records end with a kind byte. Its agent
/// panes are skipped on restore.
pub const pane_kind_version: u16 = 4;

pub const LegacyPaneKind = enum(u8) {
    terminal = 0,
    agent = 1,
};

pub const Kind = enum(u8) {
    end = 0,
    workspace = 1,
    tab = 2,
    pane = 3,
    layout = 4,
    worktree = 5,
};

/// An empty title carries no source. A present one must be printable and
/// come from a durable source, so restore never revives a placeholder.
pub fn validateTitle(title: []const u8, source: u8) !void {
    if (title.len == 0) {
        if (source != 0) {
            return error.InvalidCheckpoint;
        }

        return;
    }

    core.validateSessionTitle(title) catch return error.InvalidCheckpoint;
    switch (std.enums.fromInt(core.AgentTitleSource, source) orelse return error.InvalidCheckpoint) {
        .generated, .manual, .agent => {},
        .telar, .terminal => return error.InvalidCheckpoint,
    }
}

/// A worktree record carries an absolute path and text every client can
/// decode, by the same rule the wire and the runtime's table apply.
pub fn validateWorktree(record: WorktreeRecord) !void {
    try validatePath(record.path);
    if (record.id == 0 or record.source_workspace_id == 0 or record.branch.len == 0) {
        return error.InvalidCheckpoint;
    }

    if (std.enums.fromInt(core.WorktreeOrigin, record.origin) == null) {
        return error.InvalidCheckpoint;
    }

    core.validateWorktreeText(.{
        .path = record.path,
        .branch = record.branch,
        .base = record.base,
        .title = record.title,
        .brief = record.brief,
        .dispatched_from = record.dispatched_from,
    }) catch return error.InvalidCheckpoint;
}

pub fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path.len > core.max_cwd_bytes or std.mem.indexOfScalar(u8, path, 0) != null) {
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
        .agent_title_source = @intFromEnum(core.AgentTitleSource.generated),
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
    try std.testing.expectEqual(@intFromEnum(core.AgentTitleSource.generated), pane.agent_title_source);
    const layout = (try reader.next()).?.layout;
    try std.testing.expectEqual(@as(u64, 42), layout.identity);
    try std.testing.expectEqualStrings("\x1a\x01", layout.payload);
    try std.testing.expect(try reader.next() == null);
}

test "a full checkpoint keeps the records that fit and drops the rest" {
    var buffer: [128]u8 = undefined;
    var encoder = try Encoder.init(&buffer, .{
        .next_workspace_id = 2,
        .next_tab_id = 3,
        .next_pane_id = 2,
        .next_pane_generation = 2,
    });
    try encoder.workspace(.{
        .id = 1,
        .path = "/work",
        .name = "",
        .first_tab_id = 1,
        .first_tab_label = "main",
    });
    try encoder.tab(.{
        .workspace_id = 1,
        .tab_id = 2,
        .label = "logs",
    });
    try encoder.pane(.{
        .pane_id = 1,
        .workspace_id = 1,
        .tab_id = 2,
        .cwd = "/work/a/long/directory/that/does/not/fit",
        .cols = 80,
        .rows = 24,
        .arguments = "/bin/zsh\x00",
        .argument_count = 1,
    });
    try encoder.tab(.{
        .workspace_id = 1,
        .tab_id = 3,
        .label = "x",
    });
    const bytes = try encoder.finish();

    try std.testing.expectEqual(@as(u32, 2), encoder.dropped);

    var reader = try Reader.init(bytes);
    try std.testing.expectEqualStrings("/work", (try reader.next()).?.workspace.path);
    try std.testing.expectEqualStrings("logs", (try reader.next()).?.tab.label);
    try std.testing.expect(try reader.next() == null);
}

test "checkpoint labels distinguish automatic tabs from explicit former defaults" {
    var buffer: [4096]u8 = undefined;
    var encoder = try Encoder.init(&buffer, .{
        .next_workspace_id = 3,
        .next_tab_id = 5,
        .next_pane_id = 1,
        .next_pane_generation = 1,
    });
    try encoder.workspace(.{ .id = 1, .path = "/work/automatic", .name = "", .first_tab_id = 1, .first_tab_label = "" });
    try encoder.workspace(.{ .id = 2, .path = "/work/explicit", .name = "", .first_tab_id = 2, .first_tab_label = "main" });
    try encoder.tab(.{ .workspace_id = 1, .tab_id = 3, .label = "" });
    try encoder.tab(.{ .workspace_id = 2, .tab_id = 4, .label = "tab 4" });
    var reader = try Reader.init(try encoder.finish());

    try std.testing.expectEqualStrings("", (try reader.next()).?.workspace.first_tab_label);
    try std.testing.expectEqualStrings("main", (try reader.next()).?.workspace.first_tab_label);
    try std.testing.expectEqualStrings("", (try reader.next()).?.tab.label);
    try std.testing.expectEqualStrings("tab 4", (try reader.next()).?.tab.label);
    try std.testing.expect(try reader.next() == null);
}

test "an agent that kept its session in the pane is resumed that way, and older files say it did not" {
    var buffer: [1024]u8 = undefined;
    var encoder = try Encoder.init(&buffer, .{
        .next_workspace_id = 2,
        .next_tab_id = 2,
        .next_pane_id = 2,
        .next_pane_generation = 2,
    });
    try encoder.pane(.{
        .pane_id = 1,
        .workspace_id = 1,
        .tab_id = 1,
        .cwd = "/work",
        .cols = 80,
        .rows = 24,
        .arguments = "/bin/sh\x00",
        .argument_count = 1,
        .agent_provider = @intFromEnum(core.AgentProvider.codex),
        .agent_session = "019a0000-0000-7000-8000-00000000000a",
        .agent_in_pane = true,
    });
    const bytes = try encoder.finish();

    var reader = try Reader.init(bytes);
    try std.testing.expect((try reader.next()).?.pane.agent_in_pane);

    // A version 7 record ends at its title source.
    var legacy_buffer: [1024]u8 = undefined;
    @memcpy(legacy_buffer[0 .. bytes.len - 2], bytes[0 .. bytes.len - 2]);
    legacy_buffer[bytes.len - 2] = bytes[bytes.len - 1];
    std.mem.writeInt(u16, legacy_buffer[magic.len..][0..2], agent_in_pane_version - 1, .little);
    var legacy = try Reader.init(legacy_buffer[0 .. bytes.len - 1]);
    try std.testing.expect(!(try legacy.next()).?.pane.agent_in_pane);
}

test "version 2 checkpoints retain former default labels as explicit" {
    var buffer: [512]u8 = undefined;
    var encoder = try Encoder.init(&buffer, .{
        .next_workspace_id = 2,
        .next_tab_id = 3,
        .next_pane_id = 1,
        .next_pane_generation = 1,
    });
    try encoder.workspace(.{ .id = 1, .path = "/work/legacy", .name = "", .first_tab_id = 1, .first_tab_label = "main" });
    try encoder.tab(.{ .workspace_id = 1, .tab_id = 2, .label = "tab 2" });
    const bytes = try encoder.finish();
    std.mem.writeInt(u16, buffer[magic.len..][0..2], 2, .little);
    var reader = try Reader.init(bytes);

    try std.testing.expectEqual(@as(u16, 2), reader.version);
    try std.testing.expectEqualStrings("main", (try reader.next()).?.workspace.first_tab_label);
    try std.testing.expectEqualStrings("tab 2", (try reader.next()).?.tab.label);
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
    placeholder.agent_title_source = @intFromEnum(core.AgentTitleSource.telar);
    var encoder = try Encoder.init(&buffer, counters);
    try std.testing.expectError(error.InvalidCheckpoint, encoder.pane(placeholder));

    var agent_named = base;
    agent_named.agent_title = "Fix proxy";
    agent_named.agent_title_source = @intFromEnum(core.AgentTitleSource.agent);
    encoder = try Encoder.init(&buffer, counters);
    try encoder.pane(agent_named);

    var control = base;
    control.agent_title = "a\x1bb";
    control.agent_title_source = @intFromEnum(core.AgentTitleSource.manual);
    encoder = try Encoder.init(&buffer, counters);
    try std.testing.expectError(error.InvalidCheckpoint, encoder.pane(control));

    var sourced_empty = base;
    sourced_empty.agent_title_source = @intFromEnum(core.AgentTitleSource.generated);
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
    var inner = bytecodec.Encoder.init(&buffer);
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

// A pane record as versions before `agent_in_pane_version` wrote it.
fn legacyPane(encoder: *Encoder, record: PaneRecord) !void {
    try encoder.pane(record);
    encoder.inner.index -= 1;
}

test "version 4 agent pane records are skipped while terminal records restore" {
    var buffer: [1024]u8 = undefined;
    var encoder = try Encoder.init(&buffer, .{ .next_workspace_id = 2, .next_tab_id = 2, .next_pane_id = 3, .next_pane_generation = 2 });
    std.mem.writeInt(u16, buffer[magic.len..][0..2], pane_kind_version, .little);
    const terminal: PaneRecord = .{
        .pane_id = 2,
        .workspace_id = 1,
        .tab_id = 1,
        .cwd = "/work",
        .cols = 80,
        .rows = 24,
        .arguments = "/bin/sh\x00",
        .argument_count = 1,
    };
    var agent = terminal;
    agent.pane_id = 1;
    try legacyPane(&encoder, agent);
    try encoder.inner.writeByte(@intFromEnum(LegacyPaneKind.agent));
    try legacyPane(&encoder, terminal);
    try encoder.inner.writeByte(@intFromEnum(LegacyPaneKind.terminal));
    const bytes = try encoder.finish();

    var reader = try Reader.init(bytes);
    const pane = (try reader.next()).?.pane;
    try std.testing.expectEqual(@as(u64, 2), pane.pane_id);
    try std.testing.expectEqualStrings("/bin/sh\x00", pane.arguments);
    try std.testing.expect(try reader.next() == null);
}

test "version 3 pane records restore without a kind byte" {
    var buffer: [512]u8 = undefined;
    var encoder = try Encoder.init(&buffer, .{ .next_workspace_id = 2, .next_tab_id = 2, .next_pane_id = 2, .next_pane_generation = 2 });
    try legacyPane(&encoder, .{
        .pane_id = 1,
        .workspace_id = 1,
        .tab_id = 1,
        .cwd = "/work",
        .cols = 80,
        .rows = 24,
        .arguments = "/bin/sh\x00",
        .argument_count = 1,
        .agent_title = "Legacy title",
        .agent_title_source = @intFromEnum(core.AgentTitleSource.manual),
    });
    const bytes = try encoder.finish();
    std.mem.writeInt(u16, buffer[magic.len..][0..2], 3, .little);
    var reader = try Reader.init(bytes);
    const pane = (try reader.next()).?.pane;
    try std.testing.expectEqualStrings("Legacy title", pane.agent_title);
    try std.testing.expectEqualStrings("/bin/sh\x00", pane.arguments);
    try std.testing.expect(try reader.next() == null);
}

test "worktree records keep the dispatching machine from version 7 on" {
    var buffer: [512]u8 = undefined;
    const counters: Counters = .{ .next_workspace_id = 2, .next_tab_id = 1, .next_pane_id = 1, .next_pane_generation = 1 };
    const record: WorktreeRecord = .{
        .id = 4,
        .source_workspace_id = 1,
        .path = "/work/telar-worktrees/fix",
        .branch = "fix",
        .dispatched_from = "laptop",
    };
    var encoder = try Encoder.init(&buffer, counters);
    try encoder.worktree(record);
    var reader = try Reader.init(try encoder.finish());
    try std.testing.expectEqualStrings("laptop", (try reader.next()).?.worktree.dispatched_from);

    // A version 6 record ends at its brief.
    var local = record;
    local.dispatched_from = "";
    encoder = try Encoder.init(&buffer, counters);
    try encoder.worktree(local);
    const bytes = try encoder.finish();
    var legacy: [512]u8 = undefined;
    const trailing_empty_text = 2;
    const body = bytes.len - 1 - trailing_empty_text;
    @memcpy(legacy[0..body], bytes[0..body]);
    legacy[body] = bytes[bytes.len - 1];
    std.mem.writeInt(u16, legacy[magic.len..][0..2], dispatched_from_version - 1, .little);
    reader = try Reader.init(legacy[0 .. body + 1]);
    const restored = (try reader.next()).?.worktree;
    try std.testing.expectEqualStrings("fix", restored.branch);
    try std.testing.expectEqualStrings("", restored.dispatched_from);
    try std.testing.expect(try reader.next() == null);
}

test "a worktree record no client could decode is skipped, not the whole checkpoint" {
    var buffer: [1024]u8 = undefined;
    var encoder = try Encoder.init(&buffer, .{ .next_workspace_id = 2, .next_tab_id = 2, .next_pane_id = 1, .next_pane_generation = 1 });
    try encoder.workspace(.{ .id = 1, .path = "/work/telar", .name = "", .first_tab_id = 1, .first_tab_label = "main" });
    try encoder.worktree(.{ .id = 4, .source_workspace_id = 1, .path = "/work/telar-worktrees/fix-a", .branch = "fix-a" });
    try encoder.worktree(.{ .id = 5, .source_workspace_id = 1, .path = "/work/telar-worktrees/fix-b", .branch = "fix-b" });
    const bytes = try encoder.finish();

    // Cut the first branch inside a character, as a torn write could.
    var corrupt: [1024]u8 = undefined;
    @memcpy(corrupt[0..bytes.len], bytes);
    const branch = std.mem.indexOf(u8, bytes, "\x05\x00fix-a").? + 2;
    corrupt[branch + 4] = 0xc3;

    var reader = try Reader.init(corrupt[0..bytes.len]);
    try std.testing.expect((try reader.next()).? == .workspace);
    const kept = (try reader.next()).?;
    try std.testing.expectEqual(@as(u64, 5), kept.worktree.id);
    try std.testing.expect(try reader.next() == null);
    try std.testing.expectEqual(@as(u16, 1), reader.skipped_worktrees);
}

test "a worktree record with text no client could decode is refused" {
    const valid: WorktreeRecord = .{
        .id = 4,
        .source_workspace_id = 1,
        .path = "/work/telar-worktrees/fix",
        .branch = "fix",
        .base = "main",
        .title = "Fix tabs",
    };
    try validateWorktree(valid);

    var cut = valid;
    cut.branch = "fix-\xc3";
    try std.testing.expectError(error.InvalidCheckpoint, validateWorktree(cut));

    var escaped = valid;
    escaped.title = "Fix\x1b[2J";
    try std.testing.expectError(error.InvalidCheckpoint, validateWorktree(escaped));
}
