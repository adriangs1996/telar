//! Tab lifecycle inside a workspace and the per-tab pane snapshot.

const RequestTabSnapshot = @import("RequestTabSnapshot.zig");
const codec = @import("../codec.zig");
const tags = @import("tags.zig");
const CreateTab = @import("CreateTab.zig");
const EncoderType = @import("../Encoder.zig");
const id = @import("../id.zig");
const launch_mod = @import("launch.zig");
const DecoderType = @import("../Decoder.zig");
const CreateTabView = @import("CreateTabView.zig");
const RenameTab = @import("RenameTab.zig");
const CloseTab = @import("CloseTab.zig");
const MoveTab = @import("MoveTab.zig");
const TabSnapshot = @import("TabSnapshot.zig");
const types = @import("../types.zig");
const TabSnapshotView = @import("TabSnapshotView.zig");
const TabCreated = @import("TabCreated.zig");
const TabRenamed = @import("TabRenamed.zig");
const TabClosed = @import("TabClosed.zig");
const TabMoved = @import("TabMoved.zig");

pub fn encodeRequestTabSnapshot(buffer: []u8, message: RequestTabSnapshot) ![]const u8 {
    return codec.encodeDerived(
        @intFromEnum(tags.ClientTag.request_tab_snapshot),
        buffer,
        message,
    );
}

pub fn encodeCreateTab(buffer: []u8, message: CreateTab) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    try message.size.validate();
    try codec.validateTabLabel(message.label, true);
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.create_tab));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try codec.encodeWorkspaceLocation(&encoder, message.workspace);
    try encoder.writeSized16(message.label);
    try codec.encodeSize(&encoder, message.size);
    try launch_mod.encodeLaunch(&encoder, message.launch);
    return encoder.finish();
}

pub fn decodeCreateTab(decoder: *DecoderType) !CreateTabView {
    const request_id = try id.request(try decoder.readInt(u64));
    const location = try codec.decodeWorkspaceLocation(decoder);
    const label = try decoder.readSized16();
    try codec.validateTabLabel(label, true);
    return .{
        .request_id = request_id,
        .workspace = location,
        .label = label,
        .size = try codec.decodeSize(decoder),
        .launch = try launch_mod.decodeLaunch(decoder),
    };
}

pub fn encodeRenameTab(buffer: []u8, message: RenameTab) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    try codec.validateTabLabel(message.label, false);
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.rename_tab));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try codec.encodeTabLocation(&encoder, message.location);
    try encoder.writeSized16(message.label);
    return encoder.finish();
}

pub fn decodeRenameTab(decoder: *DecoderType) !RenameTab {
    const request_id = try id.request(try decoder.readInt(u64));
    const location = try codec.decodeTabLocation(decoder);
    const label = try decoder.readSized16();
    try codec.validateTabLabel(label, false);
    return .{ .request_id = request_id, .location = location, .label = label };
}

pub fn encodeCloseTab(buffer: []u8, message: CloseTab) ![]const u8 {
    return codec.encodeDerived(@intFromEnum(tags.ClientTag.close_tab), buffer, message);
}

pub fn encodeMoveTab(buffer: []u8, message: MoveTab) ![]const u8 {
    return codec.encodeDerived(@intFromEnum(tags.ClientTag.move_tab), buffer, message);
}

pub fn encodeTabSnapshot(buffer: []u8, message: TabSnapshot) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    if (message.panes.len > types.max_panes_per_tab) {
        return error.TooManyPanes;
    }

    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.tab_snapshot));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try codec.encodeTabLocation(&encoder, message.location);
    try encoder.writeInt(u16, @intCast(message.panes.len));
    for (message.panes, 0..) |pane, pane_index| {
        try codec.validatePaneId(pane.pane_id);
        for (message.panes[0..pane_index]) |previous| {
            if (previous.pane_id == pane.pane_id) {
                return error.DuplicatePane;
            }
        }
        try encoder.writeInt(u64, id.raw(pane.pane_id));
        try encoder.writeByte(@intFromEnum(pane.lifecycle));
    }
    return encoder.finish();
}

pub fn decodeTabSnapshot(decoder: *DecoderType) !TabSnapshotView {
    const request_id = try id.request(try decoder.readInt(u64));
    const location = try codec.decodeTabLocation(decoder);
    const pane_count = try decoder.readInt(u16);
    if (pane_count > types.max_panes_per_tab) {
        return error.TooManyPanes;
    }

    const panes_start = decoder.index;
    // Quadratic duplicate scan, acceptable while max_panes_per_tab is 64;
    // revisit before raising the limit.
    var seen: [types.max_panes_per_tab]id.PaneId = undefined;
    for (0..pane_count) |pane_index| {
        const pane_id = try id.pane(try decoder.readInt(u64));
        _ = try codec.decodePaneLifecycle(try decoder.readByte());
        for (seen[0..pane_index]) |previous| {
            if (previous == pane_id) {
                return error.DuplicatePane;
            }
        }
        seen[pane_index] = pane_id;
    }
    return .{
        .request_id = request_id,
        .location = location,
        .pane_count = pane_count,
        .encoded_panes = decoder.consumed(panes_start),
    };
}

pub fn encodeTabCreated(buffer: []u8, message: TabCreated) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    try codec.validatePaneId(message.root_pane_id);
    try codec.validateTabLabel(message.label, false);
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.tab_created));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try codec.encodeTabLocation(&encoder, message.location);
    try encoder.writeInt(u16, message.position);
    try encoder.writeSized16(message.label);
    try encoder.writeInt(u64, id.raw(message.root_pane_id));
    return encoder.finish();
}

pub fn decodeTabCreated(decoder: *DecoderType) !TabCreated {
    const request_id = try id.request(try decoder.readInt(u64));
    const location = try codec.decodeTabLocation(decoder);
    const position = try decoder.readInt(u16);
    const label = try decoder.readSized16();
    try codec.validateTabLabel(label, false);
    return .{
        .request_id = request_id,
        .location = location,
        .position = position,
        .label = label,
        .root_pane_id = try id.pane(try decoder.readInt(u64)),
    };
}

pub fn encodeTabRenamed(buffer: []u8, message: TabRenamed) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    try codec.validateTabLabel(message.label, false);
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.tab_renamed));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try codec.encodeTabLocation(&encoder, message.location);
    try encoder.writeSized16(message.label);
    return encoder.finish();
}

pub fn decodeTabRenamed(decoder: *DecoderType) !TabRenamed {
    const request_id = try id.request(try decoder.readInt(u64));
    const location = try codec.decodeTabLocation(decoder);
    const label = try decoder.readSized16();
    try codec.validateTabLabel(label, false);
    return .{ .request_id = request_id, .location = location, .label = label };
}

pub fn encodeTabClosed(buffer: []u8, message: TabClosed) ![]const u8 {
    return codec.encodeDerived(@intFromEnum(tags.ServerTag.tab_closed), buffer, message);
}

pub fn encodeTabMoved(buffer: []u8, message: TabMoved) ![]const u8 {
    return codec.encodeDerived(@intFromEnum(tags.ServerTag.tab_moved), buffer, message);
}
