/// Reads one checkpoint. Every slice borrows the input bytes.
///
/// ```zig
/// var reader = try Reader.init(bytes);
/// while (try reader.next()) |record| apply(record);
/// ```
const Reader = @This();
const source_namespace = @import("checkpoint.zig");
const Counters = @import("Counters.zig");
const std = @import("std");
inner: source_namespace.wire.Decoder,
counters: Counters,
version: u16,
finished: bool = false,

pub fn init(bytes: []const u8) !Reader {
    var decoder = source_namespace.wire.Decoder.init(bytes);
    const header = try decoder.readBytes(source_namespace.magic.len);
    if (!std.mem.eql(u8, header, source_namespace.magic)) {
        return error.InvalidCheckpoint;
    }
    const file_version = try decoder.readInt(u16);
    if (file_version < source_namespace.oldest_readable_version or file_version > source_namespace.version) {
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

pub fn next(reader: *Reader) !?source_namespace.Record {
    if (reader.finished) {
        return null;
    }
    const kind = std.enums.fromInt(source_namespace.Kind, try reader.inner.readByte()) orelse return error.InvalidCheckpoint;
    switch (kind) {
        .end => {
            try reader.inner.ensureEnd();
            reader.finished = true;
            return null;
        },
        .workspace => {
            const id = try reader.inner.readInt(u64);
            const path = try reader.inner.readSized16();
            try source_namespace.validatePath(path);
            const name = try reader.inner.readSized16();
            if (name.len > source_namespace.schema.max_tab_label_bytes) {
                return error.InvalidCheckpoint;
            }
            const first_tab_id = try reader.inner.readInt(u64);
            const first_tab_label = try reader.inner.readSized16();
            if (first_tab_label.len == 0 or first_tab_label.len > source_namespace.schema.max_tab_label_bytes) {
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
            if (label.len == 0 or label.len > source_namespace.schema.max_tab_label_bytes) {
                return error.InvalidCheckpoint;
            }
            return .{ .tab = .{ .workspace_id = workspace_id, .tab_id = tab_id, .label = label } };
        },
        .pane => {
            const pane_id = try reader.inner.readInt(u64);
            const workspace_id = try reader.inner.readInt(u64);
            const tab_id = try reader.inner.readInt(u64);
            const cwd = try reader.inner.readSized16();
            try source_namespace.validatePath(cwd);
            const cols = try reader.inner.readInt(u16);
            const rows = try reader.inner.readInt(u16);
            const argument_count = try reader.inner.readInt(u16);
            const arguments = try reader.inner.readSized16();
            if (argument_count == 0 or argument_count > source_namespace.max_launch_arguments or arguments.len > source_namespace.max_launch_bytes) {
                return error.InvalidCheckpoint;
            }
            if (std.mem.count(u8, arguments, "\x00") != argument_count) {
                return error.InvalidCheckpoint;
            }
            const agent_provider = try reader.inner.readByte();
            const agent_session = try reader.inner.readSized16();
            if (agent_session.len != 0) {
                source_namespace.schema.validateSessionReference(agent_session) catch return error.InvalidCheckpoint;
            }
            const agent_title = if (reader.version >= 2) try reader.inner.readSized16() else "";
            const agent_title_source = if (reader.version >= 2) try reader.inner.readByte() else 0;
            try source_namespace.validateTitle(agent_title, agent_title_source);
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
            if (payload.len == 0 or payload.len > source_namespace.schema.max_client_layout_wire_bytes) {
                return error.InvalidCheckpoint;
            }
            return .{ .layout = .{ .identity = identity, .last_used = last_used, .payload = payload } };
        },
    }
}
