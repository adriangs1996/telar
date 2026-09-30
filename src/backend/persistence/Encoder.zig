const bytecodec = @import("bytecodec");
const core = @import("telar-core");
const Counters = @import("Counters.zig");
const checkpoint = @import("checkpoint.zig");
const WorkspaceRecord = @import("WorkspaceRecord.zig");
const TabRecord = @import("TabRecord.zig");
const PaneRecord = @import("PaneRecord.zig");
const LayoutRecord = @import("LayoutRecord.zig");
const WorktreeRecord = @import("WorktreeRecord.zig");
/// Appends records to a fixed buffer. `finish` closes the stream.
///
/// A record that does not fit is dropped with every record after it, so
/// the stream keeps a prefix whose references all point back into it:
/// tabs follow their workspace and panes their tab. `dropped` counts them.
///
/// ```zig
/// var encoder = Encoder.init(buffer, counters);
/// try encoder.workspace(.{ .id = 1, .path = "/work", .name = "" });
/// const bytes = try encoder.finish();
/// ```
const Encoder = @This();

inner: bytecodec.Encoder,
/// The whole buffer; `inner` leaves its last byte for the end marker.
buffer: []u8,
/// Records left out because the buffer was full.
dropped: u32 = 0,

pub fn init(buffer: []u8, counters: Counters) !Encoder {
    if (buffer.len == 0) {
        return error.BufferTooSmall;
    }

    var encoder: Encoder = .{
        .inner = bytecodec.Encoder.init(buffer[0 .. buffer.len - 1]),
        .buffer = buffer,
    };
    try encoder.inner.writeBytes(checkpoint.magic);
    try encoder.inner.writeInt(u16, checkpoint.version);
    try encoder.inner.writeInt(u64, counters.next_workspace_id);
    try encoder.inner.writeInt(u64, counters.next_tab_id);
    try encoder.inner.writeInt(u64, counters.next_pane_id);
    try encoder.inner.writeInt(u64, counters.next_pane_generation);
    return encoder;
}

pub fn workspace(self: *Encoder, record: WorkspaceRecord) !void {
    return self.keep(writeWorkspace, record);
}

fn writeWorkspace(self: *Encoder, record: WorkspaceRecord) !void {
    try checkpoint.validatePath(record.path);
    try self.inner.writeByte(@intFromEnum(checkpoint.Kind.workspace));
    if (record.first_tab_label.len > core.max_tab_label_bytes or record.name.len > core.max_tab_label_bytes) {
        return error.InvalidCheckpoint;
    }
    try self.inner.writeInt(u64, record.id);
    try self.inner.writeSized16(record.path);
    try self.inner.writeSized16(record.name);
    try self.inner.writeInt(u64, record.first_tab_id);
    try self.inner.writeSized16(record.first_tab_label);
}

pub fn tab(self: *Encoder, record: TabRecord) !void {
    return self.keep(writeTab, record);
}

fn writeTab(self: *Encoder, record: TabRecord) !void {
    try self.inner.writeByte(@intFromEnum(checkpoint.Kind.tab));
    try self.inner.writeInt(u64, record.workspace_id);
    try self.inner.writeInt(u64, record.tab_id);
    try self.inner.writeSized16(record.label);
}

pub fn pane(self: *Encoder, record: PaneRecord) !void {
    return self.keep(writePane, record);
}

fn writePane(self: *Encoder, record: PaneRecord) !void {
    try checkpoint.validatePath(record.cwd);
    if (record.argument_count > checkpoint.max_launch_arguments or record.arguments.len > checkpoint.max_launch_bytes or record.argument_count == 0) {
        return error.InvalidLaunchRecord;
    }
    try self.inner.writeByte(@intFromEnum(checkpoint.Kind.pane));
    try self.inner.writeInt(u64, record.pane_id);
    try self.inner.writeInt(u64, record.workspace_id);
    try self.inner.writeInt(u64, record.tab_id);
    try self.inner.writeSized16(record.cwd);
    try self.inner.writeInt(u16, record.cols);
    try self.inner.writeInt(u16, record.rows);
    try self.inner.writeInt(u16, record.argument_count);
    try self.inner.writeSized16(record.arguments);
    if (record.agent_session.len > core.max_agent_session_reference_bytes) {
        return error.InvalidCheckpoint;
    }
    try self.inner.writeByte(record.agent_provider);
    try self.inner.writeSized16(record.agent_session);
    try checkpoint.validateTitle(record.agent_title, record.agent_title_source);
    try self.inner.writeSized16(record.agent_title);
    try self.inner.writeByte(record.agent_title_source);
    try self.inner.writeByte(@intFromBool(record.agent_in_pane));
}

pub fn worktree(self: *Encoder, record: WorktreeRecord) !void {
    return self.keep(writeWorktree, record);
}

fn writeWorktree(self: *Encoder, record: WorktreeRecord) !void {
    try checkpoint.validateWorktree(record);
    try self.inner.writeByte(@intFromEnum(checkpoint.Kind.worktree));
    try self.inner.writeInt(u64, record.id);
    try self.inner.writeInt(u64, record.source_workspace_id);
    try self.inner.writeInt(u64, record.workspace_id);
    try self.inner.writeInt(u64, record.created_by);
    try self.inner.writeByte(record.origin);
    try self.inner.writeSized16(record.path);
    try self.inner.writeSized16(record.branch);
    try self.inner.writeSized16(record.base);
    try self.inner.writeSized16(record.title);
    try self.inner.writeSized16(record.brief);
    try self.inner.writeSized16(record.dispatched_from);
}

pub fn layout(self: *Encoder, record: LayoutRecord) !void {
    return self.keep(writeLayout, record);
}

fn writeLayout(self: *Encoder, record: LayoutRecord) !void {
    try self.inner.writeByte(@intFromEnum(checkpoint.Kind.layout));
    try self.inner.writeInt(u64, record.identity);
    try self.inner.writeInt(u64, record.last_used);
    try self.inner.writeSized32(record.payload);
}

pub fn finish(self: *Encoder) ![]const u8 {
    self.inner.buffer = self.buffer;
    try self.inner.writeByte(@intFromEnum(checkpoint.Kind.end));
    return self.inner.finish();
}

fn keep(self: *Encoder, comptime write: anytype, record: anytype) !void {
    if (self.dropped != 0) {
        self.dropped += 1;
        return;
    }

    const start = self.inner.index;
    write(self, record) catch |err| switch (err) {
        error.BufferTooSmall => {
            self.inner.index = start;
            self.dropped = 1;
        },
        else => return err,
    };
}
