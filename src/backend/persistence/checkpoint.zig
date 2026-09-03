//! Durable session checkpoint records and their file encoding.
//!
//! The record types are deliberately separate from live aggregates and from
//! client projections (ADR 0005). A checkpoint holds only what a restart can
//! rebuild: identities, paths, labels, pane launch commands and client layout
//! replicas. File descriptors, PTYs and in-flight work are never written.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;
const wire = core.schema.wire;

pub const magic: *const [8]u8 = "TELARCKP";
/// Version 2 added the agent title to pane records; version 1 files still read.
pub const version: u16 = 2;
const oldest_readable_version: u16 = 1;
pub const max_file_bytes = 4 * 1024 * 1024;
pub const max_launch_arguments = 32;
pub const max_launch_bytes = 1024;

pub const Counters = struct {
    next_workspace_id: u64,
    next_tab_id: u64,
    next_pane_id: u64,
    next_pane_generation: u64,
};

pub const WorkspaceRecord = struct {
    id: u64,
    path: []const u8,
    /// Explicit user name, empty when the workspace derives its name.
    name: []const u8,
    /// The first tab, which every workspace owns from creation. Further tabs
    /// follow as `TabRecord`s in display order.
    first_tab_id: u64,
    first_tab_label: []const u8,
};

pub const TabRecord = struct {
    workspace_id: u64,
    tab_id: u64,
    label: []const u8,
};

pub const PaneRecord = struct {
    pane_id: u64,
    workspace_id: u64,
    tab_id: u64,
    cwd: []const u8,
    cols: u16,
    rows: u16,
    /// NUL-separated launch arguments, `argument_count` of them.
    arguments: []const u8,
    argument_count: u16,
    /// Provider index of the agent that ran here, `0` when none.
    agent_provider: u8 = 0,
    /// The agent's reported session reference, empty when unknown.
    agent_session: []const u8 = "",
    /// The session title shown for the agent, empty when it had none worth
    /// keeping. `agent_title_source` is the `AgentTitleSource` that made it.
    agent_title: []const u8 = "",
    agent_title_source: u8 = 0,
};

pub const LayoutRecord = struct {
    identity: u64,
    last_used: u64,
    /// Exactly the bytes of one `update_client_layout` request.
    payload: []const u8,
};

pub const Record = union(enum) {
    workspace: WorkspaceRecord,
    tab: TabRecord,
    pane: PaneRecord,
    layout: LayoutRecord,
};

const Kind = enum(u8) {
    end = 0,
    workspace = 1,
    tab = 2,
    pane = 3,
    layout = 4,
};

/// Appends records to a fixed buffer. `finish` closes the stream.
///
/// ```zig
/// var encoder = Encoder.init(buffer, counters);
/// try encoder.workspace(.{ .id = 1, .path = "/work", .name = "" });
/// const bytes = try encoder.finish();
/// ```
pub const Encoder = struct {
    inner: wire.Encoder,

    pub fn init(buffer: []u8, counters: Counters) !Encoder {
        var encoder: Encoder = .{ .inner = wire.Encoder.init(buffer) };
        try encoder.inner.writeBytes(magic);
        try encoder.inner.writeInt(u16, version);
        try encoder.inner.writeInt(u64, counters.next_workspace_id);
        try encoder.inner.writeInt(u64, counters.next_tab_id);
        try encoder.inner.writeInt(u64, counters.next_pane_id);
        try encoder.inner.writeInt(u64, counters.next_pane_generation);
        return encoder;
    }

    pub fn workspace(encoder: *Encoder, record: WorkspaceRecord) !void {
        try validatePath(record.path);
        try encoder.inner.writeByte(@intFromEnum(Kind.workspace));
        if (record.first_tab_label.len == 0 or record.first_tab_label.len > schema.max_tab_label_bytes or record.name.len > schema.max_tab_label_bytes) {
            return error.InvalidCheckpoint;
        }
        try encoder.inner.writeInt(u64, record.id);
        try encoder.inner.writeSized16(record.path);
        try encoder.inner.writeSized16(record.name);
        try encoder.inner.writeInt(u64, record.first_tab_id);
        try encoder.inner.writeSized16(record.first_tab_label);
    }

    pub fn tab(encoder: *Encoder, record: TabRecord) !void {
        try encoder.inner.writeByte(@intFromEnum(Kind.tab));
        try encoder.inner.writeInt(u64, record.workspace_id);
        try encoder.inner.writeInt(u64, record.tab_id);
        try encoder.inner.writeSized16(record.label);
    }

    pub fn pane(encoder: *Encoder, record: PaneRecord) !void {
        try validatePath(record.cwd);
        if (record.argument_count == 0 or record.argument_count > max_launch_arguments or record.arguments.len > max_launch_bytes) {
            return error.InvalidLaunchRecord;
        }
        try encoder.inner.writeByte(@intFromEnum(Kind.pane));
        try encoder.inner.writeInt(u64, record.pane_id);
        try encoder.inner.writeInt(u64, record.workspace_id);
        try encoder.inner.writeInt(u64, record.tab_id);
        try encoder.inner.writeSized16(record.cwd);
        try encoder.inner.writeInt(u16, record.cols);
        try encoder.inner.writeInt(u16, record.rows);
        try encoder.inner.writeInt(u16, record.argument_count);
        try encoder.inner.writeSized16(record.arguments);
        if (record.agent_session.len > schema.max_agent_session_reference_bytes) {
            return error.InvalidCheckpoint;
        }
        try encoder.inner.writeByte(record.agent_provider);
        try encoder.inner.writeSized16(record.agent_session);
        try validateTitle(record.agent_title, record.agent_title_source);
        try encoder.inner.writeSized16(record.agent_title);
        try encoder.inner.writeByte(record.agent_title_source);
    }

    pub fn layout(encoder: *Encoder, record: LayoutRecord) !void {
        try encoder.inner.writeByte(@intFromEnum(Kind.layout));
        try encoder.inner.writeInt(u64, record.identity);
        try encoder.inner.writeInt(u64, record.last_used);
        try encoder.inner.writeSized32(record.payload);
    }

    pub fn finish(encoder: *Encoder) ![]const u8 {
        try encoder.inner.writeByte(@intFromEnum(Kind.end));
        return encoder.inner.finish();
    }
};

/// Reads one checkpoint. Every slice borrows the input bytes.
///
/// ```zig
/// var reader = try Reader.init(bytes);
/// while (try reader.next()) |record| apply(record);
/// ```
pub const Reader = struct {
    inner: wire.Decoder,
    counters: Counters,
    version: u16,
    finished: bool = false,

    pub fn init(bytes: []const u8) !Reader {
        var decoder = wire.Decoder.init(bytes);
        const header = try decoder.readBytes(magic.len);
        if (!std.mem.eql(u8, header, magic)) {
            return error.InvalidCheckpoint;
        }
        const file_version = try decoder.readInt(u16);
        if (file_version < oldest_readable_version or file_version > version) {
            return error.UnsupportedCheckpointVersion;
        }
        const counters: Counters = .{
            .next_workspace_id = try decoder.readInt(u64),
            .next_tab_id = try decoder.readInt(u64),
            .next_pane_id = try decoder.readInt(u64),
            .next_pane_generation = try decoder.readInt(u64),
        };
        if (counters.next_workspace_id == 0 or counters.next_tab_id == 0 or
            counters.next_pane_id == 0 or counters.next_pane_generation == 0)
        {
            return error.InvalidCheckpoint;
        }
        return .{ .inner = decoder, .counters = counters, .version = file_version };
    }

    pub fn next(reader: *Reader) !?Record {
        if (reader.finished) {
            return null;
        }
        const kind = std.enums.fromInt(Kind, try reader.inner.readByte()) orelse return error.InvalidCheckpoint;
        switch (kind) {
            .end => {
                try reader.inner.ensureEnd();
                reader.finished = true;
                return null;
            },
            .workspace => {
                const id = try reader.inner.readInt(u64);
                const path = try reader.inner.readSized16();
                try validatePath(path);
                const name = try reader.inner.readSized16();
                if (name.len > schema.max_tab_label_bytes) {
                    return error.InvalidCheckpoint;
                }
                const first_tab_id = try reader.inner.readInt(u64);
                const first_tab_label = try reader.inner.readSized16();
                if (first_tab_label.len == 0 or first_tab_label.len > schema.max_tab_label_bytes) {
                    return error.InvalidCheckpoint;
                }
                return .{ .workspace = .{
                    .id = id,
                    .path = path,
                    .name = name,
                    .first_tab_id = first_tab_id,
                    .first_tab_label = first_tab_label,
                } };
            },
            .tab => {
                const workspace_id = try reader.inner.readInt(u64);
                const tab_id = try reader.inner.readInt(u64);
                const label = try reader.inner.readSized16();
                if (label.len == 0 or label.len > schema.max_tab_label_bytes) {
                    return error.InvalidCheckpoint;
                }
                return .{ .tab = .{ .workspace_id = workspace_id, .tab_id = tab_id, .label = label } };
            },
            .pane => {
                const pane_id = try reader.inner.readInt(u64);
                const workspace_id = try reader.inner.readInt(u64);
                const tab_id = try reader.inner.readInt(u64);
                const cwd = try reader.inner.readSized16();
                try validatePath(cwd);
                const cols = try reader.inner.readInt(u16);
                const rows = try reader.inner.readInt(u16);
                const argument_count = try reader.inner.readInt(u16);
                const arguments = try reader.inner.readSized16();
                if (argument_count == 0 or argument_count > max_launch_arguments or arguments.len > max_launch_bytes) {
                    return error.InvalidCheckpoint;
                }
                if (std.mem.count(u8, arguments, "\x00") != argument_count) {
                    return error.InvalidCheckpoint;
                }
                const agent_provider = try reader.inner.readByte();
                const agent_session = try reader.inner.readSized16();
                if (agent_session.len != 0) {
                    schema.validateSessionReference(agent_session) catch return error.InvalidCheckpoint;
                }
                const agent_title = if (reader.version >= 2) try reader.inner.readSized16() else "";
                const agent_title_source = if (reader.version >= 2) try reader.inner.readByte() else 0;
                try validateTitle(agent_title, agent_title_source);
                return .{ .pane = .{
                    .pane_id = pane_id,
                    .workspace_id = workspace_id,
                    .tab_id = tab_id,
                    .cwd = cwd,
                    .cols = cols,
                    .rows = rows,
                    .arguments = arguments,
                    .argument_count = argument_count,
                    .agent_provider = agent_provider,
                    .agent_session = agent_session,
                    .agent_title = agent_title,
                    .agent_title_source = agent_title_source,
                } };
            },
            .layout => {
                const identity = try reader.inner.readInt(u64);
                const last_used = try reader.inner.readInt(u64);
                const payload = try reader.inner.readSized32();
                if (payload.len == 0 or payload.len > schema.max_client_layout_wire_bytes) {
                    return error.InvalidCheckpoint;
                }
                return .{ .layout = .{ .identity = identity, .last_used = last_used, .payload = payload } };
            },
        }
    }
};

/// Iterates the NUL-terminated arguments of a pane record.
///
/// ```zig
/// var arguments = ArgumentIterator.init(record.arguments);
/// while (arguments.next()) |argument| use(argument);
/// ```
pub const ArgumentIterator = struct {
    remaining: []const u8,

    pub fn init(arguments: []const u8) ArgumentIterator {
        return .{ .remaining = arguments };
    }

    pub fn next(iterator: *ArgumentIterator) ?[]const u8 {
        if (iterator.remaining.len == 0) {
            return null;
        }
        const end = std.mem.indexOfScalar(u8, iterator.remaining, 0) orelse iterator.remaining.len;
        const argument = iterator.remaining[0..end];
        iterator.remaining = if (end < iterator.remaining.len) iterator.remaining[end + 1 ..] else iterator.remaining[end..];
        return argument;
    }
};

/// An empty title carries no source. A present one must be printable and
/// come from a durable source, so restore never revives a placeholder.
fn validateTitle(title: []const u8, source: u8) !void {
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

fn validatePath(path: []const u8) !void {
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
