//! Runtime-retained client layout: the per-tab split trees a client keeps
//! and the bootstrap snapshot it gets back on reconnect. Every tree is
//! validated as a complete pre-order binary tree before either side trusts it.

const std = @import("std");
const wire = @import("../wire.zig");
const id = @import("../id.zig");
const types = @import("../types.zig");
const codec = @import("../codec.zig");
const tags = @import("tags.zig");

const ClientTag = tags.ClientTag;
const ServerTag = tags.ServerTag;
const PaneId = id.PaneId;
const TabLocation = types.TabLocation;
const ClientLayoutAxis = types.ClientLayoutAxis;
const ClientLayoutNode = types.ClientLayoutNode;
const ClientTabLayout = types.ClientTabLayout;
const ClientLayoutUpdate = types.ClientLayoutUpdate;
const ClientLayoutSnapshot = types.ClientLayoutSnapshot;
const max_panes_per_tab = types.max_panes_per_tab;
const max_client_layout_tabs = types.max_client_layout_tabs;
const max_client_layout_nodes = types.max_client_layout_nodes;
const min_client_layout_ratio = types.min_client_layout_ratio;
const max_client_layout_ratio = types.max_client_layout_ratio;
const validatePaneId = codec.validatePaneId;
const encodeTabLocation = codec.encodeTabLocation;
const decodeTabLocation = codec.decodeTabLocation;

pub const ClientTabLayoutView = struct {
    location: TabLocation,
    focused_pane: PaneId,
    fullscreen: bool,
    workspace_active: bool,
    node_count: u16,
    encoded_nodes: []const u8,

    /// Iterates this validated pre-order split tree without allocating.
    ///
    /// ```zig
    /// var nodes = tab.nodes();
    /// while (try nodes.next()) |node| use(node);
    /// ```
    pub fn nodes(layout: ClientTabLayoutView) ClientLayoutNodeIterator {
        return .{ .decoder = .init(layout.encoded_nodes), .remaining = layout.node_count };
    }
};

pub const ClientLayoutUpdateView = struct {
    sidebar_visible: bool,
    sidebar_width: u16,
    workspace_list_collapsed: bool,
    active_tab: TabLocation,
    tab_count: u16,
    encoded_tabs: []const u8,

    /// Iterates the validated layouts retained by this client update.
    ///
    /// ```zig
    /// var tabs = update.tabs();
    /// while (try tabs.next()) |tab| use(tab);
    /// ```
    pub fn tabs(update: ClientLayoutUpdateView) ClientTabLayoutIterator {
        return .{ .decoder = .init(update.encoded_tabs), .remaining = update.tab_count };
    }
};

pub const ClientLayoutSnapshotView = struct {
    restored: bool,
    sidebar_visible: bool,
    sidebar_width: u16,
    workspace_list_collapsed: bool,
    active_tab: ?TabLocation,
    tab_count: u16,
    encoded_tabs: []const u8,

    /// Iterates the runtime-retained tab layouts in this bootstrap snapshot.
    ///
    /// ```zig
    /// var tabs = snapshot.tabs();
    /// while (try tabs.next()) |tab| restore(tab);
    /// ```
    pub fn tabs(snapshot: ClientLayoutSnapshotView) ClientTabLayoutIterator {
        return .{ .decoder = .init(snapshot.encoded_tabs), .remaining = snapshot.tab_count };
    }
};

pub const ClientLayoutNodeIterator = struct {
    decoder: wire.Decoder,
    remaining: u16,

    /// Decodes the next tree node, returning null after the declared count.
    ///
    /// ```zig
    /// const node = (try nodes.next()) orelse return;
    /// ```
    pub fn next(iterator: *ClientLayoutNodeIterator) !?ClientLayoutNode {
        if (iterator.remaining == 0) {
            return null;
        }

        iterator.remaining -= 1;
        return @as(?ClientLayoutNode, try decodeClientLayoutNode(&iterator.decoder));
    }
};

pub const ClientTabLayoutIterator = struct {
    decoder: wire.Decoder,
    remaining: u16,

    /// Decodes the next tab layout, returning null after the declared count.
    ///
    /// ```zig
    /// const tab = (try tabs.next()) orelse return;
    /// ```
    pub fn next(iterator: *ClientTabLayoutIterator) !?ClientTabLayoutView {
        if (iterator.remaining == 0) {
            return null;
        }

        iterator.remaining -= 1;
        return @as(?ClientTabLayoutView, try decodeClientTabLayout(&iterator.decoder));
    }
};

/// Encodes one complete current-workspace layout update.
///
/// ```zig
/// const payload = try encodeClientLayoutUpdate(&buffer, update);
/// ```
pub fn encodeClientLayoutUpdate(buffer: []u8, message: ClientLayoutUpdate) ![]const u8 {
    try validateClientLayoutUpdate(message);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.update_client_layout));
    try encoder.writeByte(@intFromBool(message.sidebar_visible));
    try encoder.writeInt(u16, message.sidebar_width);
    try encoder.writeByte(@intFromBool(message.workspace_list_collapsed));
    try encodeTabLocation(&encoder, message.active_tab);
    try encoder.writeInt(u16, @intCast(message.tabs.len));
    for (message.tabs) |tab| {
        try encodeClientTabLayout(&encoder, tab);
    }

    return encoder.finish();
}

pub fn decodeClientLayoutUpdate(decoder: *wire.Decoder) !ClientLayoutUpdateView {
    const sidebar_visible = try decoder.readBool();
    const sidebar_width = try decoder.readInt(u16);
    const workspace_list_collapsed = try decoder.readBool();
    const active_tab = try decodeTabLocation(decoder);
    const tab_count = try decoder.readInt(u16);
    if (sidebar_width == 0) {
        return error.InvalidClientLayoutWidth;
    }
    if (tab_count == 0 or tab_count > max_client_layout_tabs) {
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
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.client_layout_snapshot));
    try encoder.writeByte(@intFromBool(message.restored));
    try encoder.writeByte(@intFromBool(message.sidebar_visible));
    try encoder.writeInt(u16, message.sidebar_width);
    try encoder.writeByte(@intFromBool(message.workspace_list_collapsed));
    try encodeOptionalTabLocation(&encoder, message.active_tab);
    try encoder.writeInt(u16, @intCast(message.tabs.len));
    for (message.tabs) |tab| try encodeClientTabLayout(&encoder, tab);
    return encoder.finish();
}

pub fn decodeClientLayoutSnapshot(decoder: *wire.Decoder) !ClientLayoutSnapshotView {
    const restored = try decoder.readBool();
    const sidebar_visible = try decoder.readBool();
    const sidebar_width = try decoder.readInt(u16);
    const workspace_list_collapsed = try decoder.readBool();
    const active_tab = try decodeOptionalTabLocation(decoder);
    const tab_count = try decoder.readInt(u16);
    if (tab_count > max_client_layout_tabs) {
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

fn encodeOptionalTabLocation(encoder: *wire.Encoder, location: ?TabLocation) !void {
    try encoder.writeByte(@intFromBool(location != null));
    if (location) |value| {
        try encodeTabLocation(encoder, value);
    }
}

fn decodeOptionalTabLocation(decoder: *wire.Decoder) !?TabLocation {
    if (!try decoder.readBool()) {
        return null;
    }

    return try decodeTabLocation(decoder);
}

fn encodeClientLayoutNode(encoder: *wire.Encoder, node: ClientLayoutNode) !void {
    switch (node) {
        .pane => |pane_id| {
            try validatePaneId(pane_id);
            try encoder.writeByte(0);
            try encoder.writeInt(u64, id.raw(pane_id));
        },
        .split => |split| {
            if (split.ratio < min_client_layout_ratio or split.ratio > max_client_layout_ratio) {
                return error.InvalidClientLayoutRatio;
            }

            try encoder.writeByte(1);
            try encoder.writeByte(@intFromEnum(split.axis));
            try encoder.writeInt(u16, split.ratio);
        },
    }
}

fn decodeClientLayoutNode(decoder: *wire.Decoder) !ClientLayoutNode {
    return switch (try decoder.readByte()) {
        0 => .{ .pane = try id.pane(try decoder.readInt(u64)) },
        1 => split: {
            const axis = std.enums.fromInt(ClientLayoutAxis, try decoder.readByte()) orelse
                return error.InvalidClientLayoutAxis;
            const ratio = try decoder.readInt(u16);
            if (ratio < min_client_layout_ratio or ratio > max_client_layout_ratio) {
                return error.InvalidClientLayoutRatio;
            }

            break :split .{ .split = .{ .axis = axis, .ratio = ratio } };
        },
        else => error.InvalidClientLayoutNode,
    };
}

fn encodeClientTabLayout(encoder: *wire.Encoder, layout: ClientTabLayout) !void {
    try validateClientTabLayout(layout);
    try encodeTabLocation(encoder, layout.location);
    try encoder.writeInt(u64, id.raw(layout.focused_pane));
    try encoder.writeByte(@intFromBool(layout.fullscreen));
    try encoder.writeByte(@intFromBool(layout.workspace_active));
    try encoder.writeInt(u16, @intCast(layout.nodes.len));
    for (layout.nodes) |node| {
        try encodeClientLayoutNode(encoder, node);
    }
}

fn decodeClientTabLayout(decoder: *wire.Decoder) !ClientTabLayoutView {
    const location = try decodeTabLocation(decoder);
    const focused_pane = try id.pane(try decoder.readInt(u64));
    const fullscreen = try decoder.readBool();
    const workspace_active = try decoder.readBool();
    const node_count = try decoder.readInt(u16);
    if (node_count == 0 or node_count > max_client_layout_nodes) {
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

const ClientLayoutTreeValidation = struct {
    panes: [max_panes_per_tab]PaneId = undefined,
    pane_count: usize = 0,
    pending: usize = 1,

    fn accept(validation: *ClientLayoutTreeValidation, node: ClientLayoutNode) !void {
        if (validation.pending == 0) {
            return error.InvalidClientLayoutTree;
        }

        validation.pending -= 1;
        switch (node) {
            .pane => |pane_id| {
                try validatePaneId(pane_id);
                if (std.mem.findScalar(PaneId, validation.panes[0..validation.pane_count], pane_id) != null) {
                    return error.DuplicatePane;
                }
                if (validation.pane_count == validation.panes.len) {
                    return error.TooManyPanes;
                }

                validation.panes[validation.pane_count] = pane_id;
                validation.pane_count += 1;
            },
            .split => |split| {
                if (split.ratio < min_client_layout_ratio or split.ratio > max_client_layout_ratio) {
                    return error.InvalidClientLayoutRatio;
                }

                validation.pending += 2;
            },
        }
    }

    fn finish(validation: *const ClientLayoutTreeValidation, layout: ClientLayoutTreeSummary) !void {
        if (validation.pending != 0 or validation.pane_count == 0 or layout.node_count != validation.pane_count * 2 - 1) {
            return error.InvalidClientLayoutTree;
        }
        if (std.mem.findScalar(PaneId, validation.panes[0..validation.pane_count], layout.focused_pane) == null) {
            return error.InvalidClientLayoutFocus;
        }
        if (layout.fullscreen and validation.pane_count < 2) {
            return error.InvalidClientLayoutFullscreen;
        }
    }
};

const ClientLayoutTreeSummary = struct {
    node_count: usize,
    focused_pane: PaneId,
    fullscreen: bool,
};

fn validateClientTabLayout(layout: ClientTabLayout) !void {
    if (layout.nodes.len == 0 or layout.nodes.len > max_client_layout_nodes) {
        return error.InvalidClientLayoutNodeCount;
    }

    var validation: ClientLayoutTreeValidation = .{};
    for (layout.nodes) |node| {
        try validation.accept(node);
    }

    try validation.finish(.{
        .node_count = layout.nodes.len,
        .focused_pane = layout.focused_pane,
        .fullscreen = layout.fullscreen,
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
        .fullscreen = layout.fullscreen,
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

    if (message.sidebar_width == 0 or message.tabs.len > max_client_layout_tabs) {
        return error.InvalidClientLayoutSnapshot;
    }

    try validateClientLayoutEntries(message.active_tab, message.tabs);
}

fn validateClientLayouts(active: TabLocation, tabs: []const ClientTabLayout) !void {
    if (tabs.len == 0 or tabs.len > max_client_layout_tabs) {
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

const ClientLayoutEntry = struct {
    location: TabLocation,
    workspace_active: bool,
    node_count: usize,
};

const ClientLayoutCollection = struct {
    locations: [max_client_layout_tabs]TabLocation = undefined,
    workspace_active: [max_client_layout_tabs]bool = undefined,
    count: usize = 0,
    node_count: usize = 0,

    fn append(collection: *ClientLayoutCollection, entry: ClientLayoutEntry) !void {
        for (collection.locations[0..collection.count]) |previous| {
            if (std.meta.eql(previous, entry.location)) {
                return error.DuplicateClientLayoutTab;
            }
        }
        for (collection.locations[0..collection.count], collection.workspace_active[0..collection.count]) |previous, previous_active| {
            if (previous_active and entry.workspace_active and std.meta.eql(previous.workspace, entry.location.workspace)) {
                return error.DuplicateClientLayoutWorkspace;
            }
        }

        collection.node_count = std.math.add(usize, collection.node_count, entry.node_count) catch
            return error.TooManyClientLayoutNodes;
        if (collection.node_count > max_client_layout_nodes) {
            return error.TooManyClientLayoutNodes;
        }

        collection.locations[collection.count] = entry.location;
        collection.workspace_active[collection.count] = entry.workspace_active;
        collection.count += 1;
    }

    fn validateActive(collection: *const ClientLayoutCollection, active: TabLocation) !void {
        for (collection.locations[0..collection.count], collection.workspace_active[0..collection.count]) |location, is_workspace_active| {
            if (std.meta.eql(location, active)) {
                if (!is_workspace_active) {
                    return error.InvalidClientLayoutActiveTab;
                }

                return;
            }
        }

        return error.InvalidClientLayoutActiveTab;
    }
};
