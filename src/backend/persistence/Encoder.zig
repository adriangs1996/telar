const core = @import("telar-core");
const Counters = @import("Counters.zig");
const checkpoint = @import("checkpoint.zig");
const WorkspaceRecord = @import("WorkspaceRecord.zig");
const TabRecord = @import("TabRecord.zig");
const PaneRecord = @import("PaneRecord.zig");
const LayoutRecord = @import("LayoutRecord.zig");
/// Appends records to a fixed buffer. `finish` closes the stream.
///
/// ```zig
/// var encoder = Encoder.init(buffer, counters);
/// try encoder.workspace(.{ .id = 1, .path = "/work", .name = "" });
/// const bytes = try encoder.finish();
/// ```
const Encoder = @This();

inner: core.Encoder,

pub fn init(buffer: []u8, counters: Counters) !Encoder {
    var encoder: Encoder = .{ .inner = core.Encoder.init(buffer) };
    try encoder.inner.writeBytes(checkpoint.magic);
    try encoder.inner.writeInt(u16, checkpoint.version);
    try encoder.inner.writeInt(u64, counters.next_workspace_id);
    try encoder.inner.writeInt(u64, counters.next_tab_id);
    try encoder.inner.writeInt(u64, counters.next_pane_id);
    try encoder.inner.writeInt(u64, counters.next_pane_generation);
    return encoder;
}

pub fn workspace(self: *Encoder, record: WorkspaceRecord) !void {
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
    try self.inner.writeByte(@intFromEnum(checkpoint.Kind.tab));
    try self.inner.writeInt(u64, record.workspace_id);
    try self.inner.writeInt(u64, record.tab_id);
    try self.inner.writeSized16(record.label);
}

pub fn pane(self: *Encoder, record: PaneRecord) !void {
    try checkpoint.validatePath(record.cwd);
    if (record.argument_count > checkpoint.max_launch_arguments or record.arguments.len > checkpoint.max_launch_bytes or (record.kind == .terminal and record.argument_count == 0)) {
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
    try checkpoint.validatePaneKind(record);
    try self.inner.writeByte(@intFromEnum(record.kind));
}

pub fn layout(self: *Encoder, record: LayoutRecord) !void {
    try self.inner.writeByte(@intFromEnum(checkpoint.Kind.layout));
    try self.inner.writeInt(u64, record.identity);
    try self.inner.writeInt(u64, record.last_used);
    try self.inner.writeSized32(record.payload);
}

pub fn finish(self: *Encoder) ![]const u8 {
    try self.inner.writeByte(@intFromEnum(checkpoint.Kind.end));
    return self.inner.finish();
}
