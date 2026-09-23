const core = @import("telar-core");
const Counters = @import("Counters.zig");
const checkpoint = @import("checkpoint.zig");
const std = @import("std");
const PaneRecord = @import("PaneRecord.zig");
/// Reads one checkpoint. Every slice borrows the input bytes.
///
/// ```zig
/// var reader = try Reader.init(bytes);
/// while (try reader.next()) |record| apply(record);
/// ```
const Reader = @This();

inner: core.Decoder,
counters: Counters,
version: u16,
finished: bool = false,

pub fn init(bytes: []const u8) !Reader {
    var decoder = core.Decoder.init(bytes);
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

pub fn next(self: *Reader) !?checkpoint.Record {
    if (self.finished) {
        return null;
    }
    const kind = std.enums.fromInt(checkpoint.Kind, try self.inner.readByte()) orelse return error.InvalidCheckpoint;
    switch (kind) {
        .end => {
            try self.inner.ensureEnd();
            self.finished = true;
            return null;
        },
        .workspace => {
            const id = try self.inner.readInt(u64);
            const path = try self.inner.readSized16();
            try checkpoint.validatePath(path);
            const name = try self.inner.readSized16();
            if (name.len > core.max_tab_label_bytes) {
                return error.InvalidCheckpoint;
            }
            const first_tab_id = try self.inner.readInt(u64);
            const first_tab_label = try self.inner.readSized16();
            if ((self.version < 3 and first_tab_label.len == 0) or first_tab_label.len > core.max_tab_label_bytes) {
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
            const workspace_id = try self.inner.readInt(u64);
            const tab_id = try self.inner.readInt(u64);
            const label = try self.inner.readSized16();
            if ((self.version < 3 and label.len == 0) or label.len > core.max_tab_label_bytes) {
                return error.InvalidCheckpoint;
            }
            return .{ .tab = .{ .workspace_id = workspace_id, .tab_id = tab_id, .label = label } };
        },
        .pane => {
            const pane_id = try self.inner.readInt(u64);
            const workspace_id = try self.inner.readInt(u64);
            const tab_id = try self.inner.readInt(u64);
            const cwd = try self.inner.readSized16();
            try checkpoint.validatePath(cwd);
            const cols = try self.inner.readInt(u16);
            const rows = try self.inner.readInt(u16);
            const argument_count = try self.inner.readInt(u16);
            const arguments = try self.inner.readSized16();
            if (argument_count > checkpoint.max_launch_arguments or arguments.len > checkpoint.max_launch_bytes) {
                return error.InvalidCheckpoint;
            }
            if (std.mem.count(u8, arguments, "\x00") != argument_count) {
                return error.InvalidCheckpoint;
            }
            const agent_provider = try self.inner.readByte();
            const agent_session = try self.inner.readSized16();
            if (agent_session.len != 0) {
                core.validateSessionReference(agent_session) catch return error.InvalidCheckpoint;
            }
            const agent_title = if (self.version >= 2) try self.inner.readSized16() else "";
            const agent_title_source = if (self.version >= 2) try self.inner.readByte() else 0;
            try checkpoint.validateTitle(agent_title, agent_title_source);
            const kind_value = if (self.version >= 4) try self.inner.readByte() else 0;
            const pane_kind = std.enums.fromInt(core.PaneKind, kind_value) orelse return error.InvalidCheckpoint;
            const pane: PaneRecord = .{
                .kind = pane_kind,
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
            };
            try checkpoint.validatePaneKind(pane);
            return .{ .pane = pane };
        },
        .layout => {
            const identity = try self.inner.readInt(u64);
            const last_used = try self.inner.readInt(u64);
            const payload = try self.inner.readSized32();
            if (payload.len == 0 or payload.len > core.max_client_layout_wire_bytes) {
                return error.InvalidCheckpoint;
            }
            return .{ .layout = .{ .identity = identity, .last_used = last_used, .payload = payload } };
        },
    }
}
