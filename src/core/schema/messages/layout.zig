//! Runtime-retained client layout: the per-tab split trees a client keeps
//! and the bootstrap snapshot it gets back on reconnect. Every tree is
//! validated as a complete pre-order binary tree before either side trusts it.

const ClientLayoutUpdate = @import("../ClientLayoutUpdate.zig");
const EncoderType = @import("../Encoder.zig");
const tags = @import("tags.zig");
const codec = @import("../codec.zig");
const DecoderType = @import("../Decoder.zig");
const ClientLayoutUpdateView = @import("ClientLayoutUpdateView.zig");
const types = @import("../types.zig");
const ClientLayoutCollection = @import("ClientLayoutCollection.zig");
const ClientLayoutSnapshot = @import("../ClientLayoutSnapshot.zig");
const ClientLayoutSnapshotView = @import("ClientLayoutSnapshotView.zig");
const TabLocation = @import("../TabLocation.zig");
const id = @import("../id.zig");
const std = @import("std");
const ClientTabLayout = @import("../ClientTabLayout.zig");
const ClientTabLayoutView = @import("ClientTabLayoutView.zig");
const ClientLayoutTreeValidation = @import("ClientLayoutTreeValidation.zig");

/// Encodes one complete current-workspace layout update.
///
/// ```zig
/// const payload = try encodeClientLayoutUpdate(&buffer, update);
/// ```
pub fn encodeClientLayoutUpdate(buffer: []u8, message: ClientLayoutUpdate) ![]const u8 {
    try validateClientLayoutUpdate(message);
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.update_client_layout));
    try encoder.writeByte(@intFromBool(message.sidebar_visible));
    try encoder.writeInt(u16, message.sidebar_width);
    try encoder.writeByte(@intFromBool(message.workspace_list_collapsed));
    try codec.encodeTabLocation(&encoder, message.active_tab);
    try encoder.writeInt(u16, @intCast(message.tabs.len));
    for (message.tabs) |tab| {
        try encodeClientTabLayout(&encoder, tab);
    }

    return encoder.finish();
}

pub fn decodeClientLayoutUpdate(decoder: *DecoderType) !ClientLayoutUpdateView {
    const sidebar_visible = try decoder.readBool();
    const sidebar_width = try decoder.readInt(u16);
    const workspace_list_collapsed = try decoder.readBool();
    const active_tab = try codec.decodeTabLocation(decoder);
    const tab_count = try decoder.readInt(u16);
    if (sidebar_width == 0) {
        return error.InvalidClientLayoutWidth;
    }
    if (tab_count == 0 or tab_count > types.max_client_layout_tabs) {
        return error.InvalidClientLayoutSnapshot;
    }

    var collection: ClientLayoutCollection = .{};
    const tabs_start = decoder.index;
    for (0..tab_count) |_| {
        const tab = try decodeClientTabLayout(decoder);
        try collection.append(.{
            .location = tab.location,
            .workspace_active = tab.workspace_active,
            .node_count = tab.node_count,
        });
    }

    try collection.validateActive(active_tab);
    return .{
        .sidebar_visible = sidebar_visible,
        .sidebar_width = sidebar_width,
        .workspace_list_collapsed = workspace_list_collapsed,
        .active_tab = active_tab,
        .tab_count = tab_count,
        .encoded_tabs = decoder.consumed(tabs_start),
    };
}

/// Encodes one bounded runtime-retained layout bootstrap snapshot.
///
/// ```zig
/// const payload = try encodeClientLayoutSnapshot(&buffer, snapshot);
/// ```
pub fn encodeClientLayoutSnapshot(buffer: []u8, message: ClientLayoutSnapshot) ![]const u8 {
    try validateClientLayoutSnapshot(message);
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.client_layout_snapshot));
    try encoder.writeByte(@intFromBool(message.restored));
    try encoder.writeByte(@intFromBool(message.sidebar_visible));
    try encoder.writeInt(u16, message.sidebar_width);
    try encoder.writeByte(@intFromBool(message.workspace_list_collapsed));
    try encodeOptionalTabLocation(&encoder, message.active_tab);
    try encoder.writeInt(u16, @intCast(message.tabs.len));
    for (message.tabs) |tab| try encodeClientTabLayout(&encoder, tab);
    return encoder.finish();
}

pub fn decodeClientLayoutSnapshot(decoder: *DecoderType) !ClientLayoutSnapshotView {
    const restored = try decoder.readBool();
    const sidebar_visible = try decoder.readBool();
    const sidebar_width = try decoder.readInt(u16);
    const workspace_list_collapsed = try decoder.readBool();
    const active_tab = try decodeOptionalTabLocation(decoder);
    const tab_count = try decoder.readInt(u16);
    if (tab_count > types.max_client_layout_tabs) {
        return error.TooManyClientLayoutTabs;
    }
    if (!restored) {
        if (sidebar_width != 0 or active_tab != null or tab_count != 0) {
            return error.InvalidEmptyClientLayout;
        }
    } else if (sidebar_width == 0) {
        return error.InvalidClientLayoutSnapshot;
    }

    var collection: ClientLayoutCollection = .{};
    const tabs_start = decoder.index;
    for (0..tab_count) |_| {
        const tab = try decodeClientTabLayout(decoder);
        try collection.append(.{
            .location = tab.location,
            .workspace_active = tab.workspace_active,
            .node_count = tab.node_count,
        });
    }
    if (active_tab) |active| {
        try collection.validateActive(active);
    }

    return .{
        .restored = restored,
        .sidebar_visible = sidebar_visible,
        .sidebar_width = sidebar_width,
        .workspace_list_collapsed = workspace_list_collapsed,
        .active_tab = active_tab,
        .tab_count = tab_count,
        .encoded_tabs = decoder.consumed(tabs_start),
    };
}

fn encodeOptionalTabLocation(encoder: *EncoderType, location: ?TabLocation) !void {
    try encoder.writeByte(@intFromBool(location != null));
    if (location) |value| {
        try codec.encodeTabLocation(encoder, value);
    }
}

fn decodeOptionalTabLocation(decoder: *DecoderType) !?TabLocation {
    if (!try decoder.readBool()) {
        return null;
    }

    return try codec.decodeTabLocation(decoder);
}

fn encodeClientLayoutNode(encoder: *EncoderType, node: types.ClientLayoutNode) !void {
    switch (node) {
        .pane => |pane| {
            try codec.validatePaneId(pane.id);
            try encoder.writeByte(0);
            try encoder.writeInt(u64, id.raw(pane.id));
            try encoder.writeByte(@intFromEnum(pane.surface));
        },
        .split => |split| {
            if (split.ratio < types.min_client_layout_ratio or split.ratio > types.max_client_layout_ratio) {
                return error.InvalidClientLayoutRatio;
            }

            try encoder.writeByte(1);
            try encoder.writeByte(@intFromEnum(split.axis));
            try encoder.writeInt(u16, split.ratio);
        },
    }
}

pub fn decodeClientLayoutNode(decoder: *DecoderType) !types.ClientLayoutNode {
    return switch (try decoder.readByte()) {
        0 => pane: {
            const pane_id = try id.pane(try decoder.readInt(u64));
            const surface = std.enums.fromInt(types.PaneSurface, try decoder.readByte()) orelse
                return error.InvalidPaneSurface;

            break :pane .{ .pane = .{ .id = pane_id, .surface = surface } };
        },
        1 => split: {
            const axis = std.enums.fromInt(types.ClientLayoutAxis, try decoder.readByte()) orelse
                return error.InvalidClientLayoutAxis;
            const ratio = try decoder.readInt(u16);
            if (ratio < types.min_client_layout_ratio or ratio > types.max_client_layout_ratio) {
                return error.InvalidClientLayoutRatio;
            }

            break :split .{ .split = .{ .axis = axis, .ratio = ratio } };
        },
        else => error.InvalidClientLayoutNode,
    };
}

fn encodeClientTabLayout(encoder: *EncoderType, layout: ClientTabLayout) !void {
    try validateClientTabLayout(layout);
    try codec.encodeTabLocation(encoder, layout.location);
    try encoder.writeInt(u64, id.raw(layout.focused_pane));
    try encoder.writeByte(@intFromBool(layout.fullscreen));
    try encoder.writeByte(@intFromBool(layout.workspace_active));
    try encoder.writeInt(u16, @intCast(layout.nodes.len));
    for (layout.nodes) |node| {
        try encodeClientLayoutNode(encoder, node);
    }
}

pub fn decodeClientTabLayout(decoder: *DecoderType) !ClientTabLayoutView {
    const location = try codec.decodeTabLocation(decoder);
    const focused_pane = try id.pane(try decoder.readInt(u64));
    const fullscreen = try decoder.readBool();
    const workspace_active = try decoder.readBool();
    const node_count = try decoder.readInt(u16);
    if (node_count == 0 or node_count > types.max_client_layout_nodes) {
        return error.InvalidClientLayoutNodeCount;
    }

    const nodes_start = decoder.index;
    for (0..node_count) |_| _ = try decodeClientLayoutNode(decoder);
    const view: ClientTabLayoutView = .{
        .location = location,
        .focused_pane = focused_pane,
        .fullscreen = fullscreen,
        .workspace_active = workspace_active,
        .node_count = node_count,
        .encoded_nodes = decoder.consumed(nodes_start),
    };
    try validateClientTabLayoutView(view);
    return view;
}

fn validateClientTabLayout(layout: ClientTabLayout) !void {
    if (layout.nodes.len == 0 or layout.nodes.len > types.max_client_layout_nodes) {
        return error.InvalidClientLayoutNodeCount;
    }

    var validation: ClientLayoutTreeValidation = .{};
    for (layout.nodes) |node| {
        try validation.accept(node);
    }

    try validation.finish(.{
        .node_count = layout.nodes.len,
        .focused_pane = layout.focused_pane,
    });
}

fn validateClientTabLayoutView(layout: ClientTabLayoutView) !void {
    var validation: ClientLayoutTreeValidation = .{};
    var nodes = layout.nodes();
    while (try nodes.next()) |node| {
        try validation.accept(node);
    }

    try validation.finish(.{
        .node_count = layout.node_count,
        .focused_pane = layout.focused_pane,
    });
}

fn validateClientLayoutUpdate(message: ClientLayoutUpdate) !void {
    if (message.sidebar_width == 0) {
        return error.InvalidClientLayoutWidth;
    }

    try validateClientLayouts(message.active_tab, message.tabs);
}

fn validateClientLayoutSnapshot(message: ClientLayoutSnapshot) !void {
    if (!message.restored) {
        if (message.sidebar_width != 0 or message.active_tab != null or message.tabs.len != 0) {
            return error.InvalidEmptyClientLayout;
        }

        return;
    }

    if (message.sidebar_width == 0 or message.tabs.len > types.max_client_layout_tabs) {
        return error.InvalidClientLayoutSnapshot;
    }

    try validateClientLayoutEntries(message.active_tab, message.tabs);
}

fn validateClientLayouts(active: TabLocation, tabs: []const ClientTabLayout) !void {
    if (tabs.len == 0 or tabs.len > types.max_client_layout_tabs) {
        return error.InvalidClientLayoutSnapshot;
    }

    try validateClientLayoutEntries(active, tabs);
}

fn validateClientLayoutEntries(active: ?TabLocation, tabs: []const ClientTabLayout) !void {
    var collection: ClientLayoutCollection = .{};
    for (tabs) |tab| {
        try validateClientTabLayout(tab);
        try collection.append(.{
            .location = tab.location,
            .workspace_active = tab.workspace_active,
            .node_count = tab.nodes.len,
        });
    }

    if (active) |location| {
        try collection.validateActive(location);
    }
}
