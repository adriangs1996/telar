const DecoderType = @import("telar-core").Decoder;
const Counters = @import("Counters.zig");
const checkpoint = @import("checkpoint.zig");
const std = @import("std");
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const validateSessionReference_module = @import("telar-core").validateSessionReference;
const max_client_layout_wire_bytes_module = @import("telar-core").max_client_layout_wire_bytes;
/// Reads one checkpoint. Every slice borrows the input bytes.
///
/// ```zig
/// var reader = try Reader.init(bytes);
/// while (try reader.next()) |record| apply(record);
/// ```
const Reader = @This();

inner: DecoderType,
counters: Counters,
version: u16,
finished: bool = false,

pub fn init(bytes: []const u8) !Reader {
    var decoder = DecoderType.init(bytes);
    const header = try decoder.readBytes(checkpoint.magic.len);
    if (!std.mem.eql(u8, header, checkpoint.magic)) {
        return error.InvalidCheckpoint;
    }
    const file_version = try decoder.readInt(u16);
    if (file_version < checkpoint.oldest_readable_version or file_version > checkpoint.version) {
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

pub fn next(reader: *Reader) !?checkpoint.Record {
    if (reader.finished) {
        return null;
    }
    const kind = std.enums.fromInt(checkpoint.Kind, try reader.inner.readByte()) orelse return error.InvalidCheckpoint;
    switch (kind) {
        .end => {
            try reader.inner.ensureEnd();
            reader.finished = true;
            return null;
        },
        .workspace => {
            const id = try reader.inner.readInt(u64);
            const path = try reader.inner.readSized16();
            try checkpoint.validatePath(path);
            const name = try reader.inner.readSized16();
            if (name.len > max_tab_label_bytes_module) {
                return error.InvalidCheckpoint;
            }
            const first_tab_id = try reader.inner.readInt(u64);
            const first_tab_label = try reader.inner.readSized16();
            if (first_tab_label.len == 0 or first_tab_label.len > max_tab_label_bytes_module) {
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
            if (label.len == 0 or label.len > max_tab_label_bytes_module) {
                return error.InvalidCheckpoint;
            }
            return .{ .tab = .{ .workspace_id = workspace_id, .tab_id = tab_id, .label = label } };
        },
        .pane => {
            const pane_id = try reader.inner.readInt(u64);
            const workspace_id = try reader.inner.readInt(u64);
            const tab_id = try reader.inner.readInt(u64);
            const cwd = try reader.inner.readSized16();
            try checkpoint.validatePath(cwd);
            const cols = try reader.inner.readInt(u16);
            const rows = try reader.inner.readInt(u16);
            const argument_count = try reader.inner.readInt(u16);
            const arguments = try reader.inner.readSized16();
            if (argument_count == 0 or argument_count > checkpoint.max_launch_arguments or arguments.len > checkpoint.max_launch_bytes) {
                return error.InvalidCheckpoint;
            }
            if (std.mem.count(u8, arguments, "\x00") != argument_count) {
                return error.InvalidCheckpoint;
            }
            const agent_provider = try reader.inner.readByte();
            const agent_session = try reader.inner.readSized16();
            if (agent_session.len != 0) {
                validateSessionReference_module(agent_session) catch return error.InvalidCheckpoint;
            }
            const agent_title = if (reader.version >= 2) try reader.inner.readSized16() else "";
            const agent_title_source = if (reader.version >= 2) try reader.inner.readByte() else 0;
            try checkpoint.validateTitle(agent_title, agent_title_source);
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
            if (payload.len == 0 or payload.len > max_client_layout_wire_bytes_module) {
                return error.InvalidCheckpoint;
            }
            return .{ .layout = .{ .identity = identity, .last_used = last_used, .payload = payload } };
        },
    }
}
