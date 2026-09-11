/// Appends records to a fixed buffer. `finish` closes the stream.
///
/// ```zig
/// var encoder = Encoder.init(buffer, counters);
/// try encoder.workspace(.{ .id = 1, .path = "/work", .name = "" });
/// const bytes = try encoder.finish();
/// ```
const Encoder = @This();
const source_namespace = @import("checkpoint.zig");
const Counters = @import("Counters.zig");
const WorkspaceRecord = @import("WorkspaceRecord.zig");
const TabRecord = @import("TabRecord.zig");
const PaneRecord = @import("PaneRecord.zig");
const LayoutRecord = @import("LayoutRecord.zig");
inner: source_namespace.wire.Encoder,

pub fn init(buffer: []u8, counters: Counters) !Encoder {
    var encoder: Encoder = .{ .inner = source_namespace.wire.Encoder.init(buffer) };
    try encoder.inner.writeBytes(source_namespace.magic);
    try encoder.inner.writeInt(u16, source_namespace.version);
    try encoder.inner.writeInt(u64, counters.next_workspace_id);
    try encoder.inner.writeInt(u64, counters.next_tab_id);
    try encoder.inner.writeInt(u64, counters.next_pane_id);
    try encoder.inner.writeInt(u64, counters.next_pane_generation);
    return encoder;
}

pub fn workspace(encoder: *Encoder, record: WorkspaceRecord) !void {
    try source_namespace.validatePath(record.path);
    try encoder.inner.writeByte(@intFromEnum(source_namespace.Kind.workspace));
    if (record.first_tab_label.len == 0 or record.first_tab_label.len > source_namespace.schema.max_tab_label_bytes or record.name.len > source_namespace.schema.max_tab_label_bytes) {
        return error.InvalidCheckpoint;
    }
    try encoder.inner.writeInt(u64, record.id);
    try encoder.inner.writeSized16(record.path);
    try encoder.inner.writeSized16(record.name);
    try encoder.inner.writeInt(u64, record.first_tab_id);
    try encoder.inner.writeSized16(record.first_tab_label);
}

pub fn tab(encoder: *Encoder, record: TabRecord) !void {
    try encoder.inner.writeByte(@intFromEnum(source_namespace.Kind.tab));
    try encoder.inner.writeInt(u64, record.workspace_id);
    try encoder.inner.writeInt(u64, record.tab_id);
    try encoder.inner.writeSized16(record.label);
}

pub fn pane(encoder: *Encoder, record: PaneRecord) !void {
    try source_namespace.validatePath(record.cwd);
    if (record.argument_count == 0 or record.argument_count > source_namespace.max_launch_arguments or record.arguments.len > source_namespace.max_launch_bytes) {
        return error.InvalidLaunchRecord;
    }
    try encoder.inner.writeByte(@intFromEnum(source_namespace.Kind.pane));
    try encoder.inner.writeInt(u64, record.pane_id);
    try encoder.inner.writeInt(u64, record.workspace_id);
    try encoder.inner.writeInt(u64, record.tab_id);
    try encoder.inner.writeSized16(record.cwd);
    try encoder.inner.writeInt(u16, record.cols);
    try encoder.inner.writeInt(u16, record.rows);
    try encoder.inner.writeInt(u16, record.argument_count);
    try encoder.inner.writeSized16(record.arguments);
    if (record.agent_session.len > source_namespace.schema.max_agent_session_reference_bytes) {
        return error.InvalidCheckpoint;
    }
    try encoder.inner.writeByte(record.agent_provider);
    try encoder.inner.writeSized16(record.agent_session);
    try source_namespace.validateTitle(record.agent_title, record.agent_title_source);
    try encoder.inner.writeSized16(record.agent_title);
    try encoder.inner.writeByte(record.agent_title_source);
}

pub fn layout(encoder: *Encoder, record: LayoutRecord) !void {
    try encoder.inner.writeByte(@intFromEnum(source_namespace.Kind.layout));
    try encoder.inner.writeInt(u64, record.identity);
    try encoder.inner.writeInt(u64, record.last_used);
    try encoder.inner.writeSized32(record.payload);
}

pub fn finish(encoder: *Encoder) ![]const u8 {
    try encoder.inner.writeByte(@intFromEnum(source_namespace.Kind.end));
    return encoder.inner.finish();
}
