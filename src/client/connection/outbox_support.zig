//! Bounded, allocation-free queue for messages sent by one frontend client.
//!
//! Variable input, creation labels, rename, notification, and launch-cwd bytes are copied
//! because their producers may reuse or replace their buffers as soon as the
//! event handler returns. One encoded buffer is borrowed only while a send
//! actor is active.

const max_panes_per_tab_module = @import("telar-core").max_panes_per_tab;
const OpenPaneType = @import("telar-core").OpenPane;
const OwnedInput = @import("OwnedInput.zig");
const PaneResizeType = @import("telar-core").PaneResize;
const FrameAckType = @import("telar-core").FrameAck;
const RequestSnapshotType = @import("telar-core").RequestSnapshot;
const DetachPaneType = @import("telar-core").DetachPane;
const RequestTabSnapshotType = @import("telar-core").RequestTabSnapshot;
const CreatePaneType = @import("telar-core").CreatePane;
const ClosePaneType = @import("telar-core").ClosePane;
const RequestWorkspaceSnapshotType = @import("telar-core").RequestWorkspaceSnapshot;
const OwnedCreateTab = @import("OwnedCreateTab.zig");
const OwnedRename = @import("OwnedRename.zig");
const CloseTabType = @import("telar-core").CloseTab;
const MoveTabType = @import("telar-core").MoveTab;
const RequestGraphicsSnapshotType = @import("telar-core").RequestGraphicsSnapshot;
const GraphicsCreditType = @import("telar-core").GraphicsCredit;
const ConfigureGraphicsType = @import("telar-core").ConfigureGraphics;
const TerminalColors = @import("telar-core").TerminalColors;
const RequestRuntimeStateType = @import("telar-core").RequestRuntimeState;
const OwnedCreateWorkspace = @import("OwnedCreateWorkspace.zig");
const OwnedWorkspaceRename = @import("OwnedWorkspaceRename.zig");
const SetPaneViewportType = @import("telar-core").SetPaneViewport;
const CopySelectionType = @import("telar-core").CopySelection;
const OwnedNotification = @import("OwnedNotification.zig");
const AcknowledgeAgentType = @import("telar-core").AcknowledgeAgent;
const OwnedSearch = @import("OwnedSearch.zig");
const OwnedHistoryQuery = @import("OwnedHistoryQuery.zig");
const DeleteHistoryType = @import("telar-core").DeleteHistory;
const ReadHistoryOutputType = @import("telar-core").ReadHistoryOutput;
const OwnedSuggestion = @import("OwnedSuggestion.zig");
const CompletePaneFocusType = @import("telar-core").CompletePaneFocus;
const Outbox = @import("Outbox.zig");
const std = @import("std");
const decodeClient_module = @import("telar-core").decodeClient;
const input_capability = @import("../input/input_namespace.zig");
const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const ClientLayoutNodeType = @import("telar-core").ClientLayoutNode;
const ClientTabLayoutType = @import("telar-core").ClientTabLayout;
const ClientLayoutUpdateType = @import("telar-core").ClientLayoutUpdate;
const max_client_layout_wire_bytes_module = @import("telar-core").max_client_layout_wire_bytes;

pub const capacity = max_panes_per_tab_module + 16;

/// Request groups permit at most one pane launch, one tab launch, and one
/// workspace launch at once. Keep one spare for bootstrap or recovery.
pub const max_pending_launches = 4;

pub const Message = union(enum) {
    open_pane: OpenPaneType,
    pane_input: OwnedInput,
    pane_resize: PaneResizeType,
    frame_ack: FrameAckType,
    request_snapshot: RequestSnapshotType,
    detach_pane: DetachPaneType,
    request_tab_snapshot: RequestTabSnapshotType,
    create_pane: CreatePaneType,
    close_pane: ClosePaneType,
    request_workspace_snapshot: RequestWorkspaceSnapshotType,
    create_tab: OwnedCreateTab,
    rename_tab: OwnedRename,
    close_tab: CloseTabType,
    move_tab: MoveTabType,
    request_graphics_snapshot: RequestGraphicsSnapshotType,
    graphics_credit: GraphicsCreditType,
    configure_graphics: ConfigureGraphicsType,
    configure_terminal_colors: TerminalColors,
    request_runtime_state: RequestRuntimeStateType,
    create_workspace: OwnedCreateWorkspace,
    rename_workspace: OwnedWorkspaceRename,
    set_pane_viewport: SetPaneViewportType,
    copy_selection: CopySelectionType,
    show_notification: OwnedNotification,
    client_layout: u8,
    acknowledge_agent: AcknowledgeAgentType,
    search_pane: OwnedSearch,
    query_history: OwnedHistoryQuery,
    delete_history: DeleteHistoryType,
    read_history_output: ReadHistoryOutputType,
    suggest_command: OwnedSuggestion,
    complete_pane_focus: CompletePaneFocusType,
};

pub fn messageLaunchCwd(message: Message) ?[]const u8 {
    return switch (message) {
        .open_pane => |value| if (value.launch) |launch| launch.cwd else null,
        .create_pane => |value| value.launch.cwd,
        .create_tab => |value| value.launch.cwd,
        .create_workspace => |value| value.launch.cwd,
        else => null,
    };
}

test "adjacent input for one pane is folded without allocation" {
    var outbox: Outbox = .{};
    try outbox.pushInput(@enumFromInt(1), "abc");
    try outbox.pushInput(@enumFromInt(1), "def");
    try std.testing.expectEqual(@as(u8, 1), outbox.len);
    try std.testing.expectEqual(@as(u64, 1), outbox.stats.coalesced_input);

    var buffer: [64]u8 = undefined;
    const decoded = try decodeClient_module((try outbox.beginSend(&buffer)).?);
    try std.testing.expectEqualStrings("abcdef", decoded.pane_input.bytes);
}

test "a long paste reserves all chunks before mutating the outbox" {
    var outbox: Outbox = .{};
    const command = "x" ** (input_capability.max_encoded_bytes + 128);
    const pane_id: PaneIdType = @enumFromInt(1);
    while (outbox.availableCapacity() > 1) {
        try outbox.push(.{ .delete_history = .{ .request_id = @enumFromInt(outbox.len + 1), .id = 1 } });
    }

    const before = outbox.len;
    try std.testing.expectError(error.ClientOutboxFull, outbox.pushInputBatch(pane_id, command));
    try std.testing.expectEqual(before, outbox.len);
    var drain_buffer: [256]u8 = undefined;
    while (try outbox.beginSend(&drain_buffer)) |_| {
        try outbox.finishSend({});
    }

    try outbox.pushInputBatch(pane_id, command);
    var buffer: [input_capability.max_encoded_bytes + 64]u8 = undefined;
    var offset: usize = 0;
    while (try outbox.beginSend(&buffer)) |encoded| {
        const message = try decodeClient_module(encoded);
        const input = message.pane_input;
        try std.testing.expectEqual(pane_id, input.pane_id);
        try std.testing.expectEqualStrings(command[offset..][0..input.bytes.len], input.bytes);
        offset += input.bytes.len;
        try outbox.finishSend({});
    }

    try std.testing.expectEqual(command.len, offset);
}

test "queue metadata stays small when input storage grows" {
    try std.testing.expect(@sizeOf(Message) < 512);
    try std.testing.expect(@sizeOf(Outbox) < 720 * 1024);
}

test "queued launches own cwd bytes until encoding" {
    var outbox: Outbox = .{};
    const pane_id: PaneIdType = @enumFromInt(1);
    try outbox.push(.{ .pane_resize = .{
        .pane_id = pane_id,
        .size = .{ .cols = 20, .rows = 10 },
    } });
    var buffer: [256]u8 = undefined;
    _ = (try outbox.beginSend(&buffer)).?;

    var cwd = "/work/first".*;
    try outbox.push(.{ .create_pane = .{
        .request_id = @enumFromInt(2),
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(3) },
            .tab_id = @enumFromInt(4),
        },
        .size = .{ .cols = 20, .rows = 10 },
        .launch = .{
            .cwd = &cwd,
            .cwd_source = pane_id,
            .arguments = &.{"/bin/sh"},
        },
    } });
    @memset(&cwd, 'x');

    outbox.popSent();
    const decoded = try decodeClient_module((try outbox.beginSend(&buffer)).?);
    try std.testing.expectEqualStrings("/work/first", decoded.create_pane.launch.cwd);
    try std.testing.expectEqual(pane_id, decoded.create_pane.launch.cwd_source.?);
}

test "queued tab rename owns bounded label bytes until encoding" {
    var outbox: Outbox = .{};
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(3) },
        .tab_id = @enumFromInt(4),
    };
    const too_long = [_]u8{'x'} ** (max_tab_label_bytes_module + 1);

    try std.testing.expectError(error.InvalidTabLabel, outbox.pushRename(.{
        .request_id = @enumFromInt(1),
        .location = location,
        .label = "",
    }));
    try std.testing.expectError(error.InvalidTabLabel, outbox.pushRename(.{
        .request_id = @enumFromInt(1),
        .location = location,
        .label = &too_long,
    }));

    try outbox.push(.{ .pane_resize = .{
        .pane_id = @enumFromInt(1),
        .size = .{ .cols = 20, .rows = 10 },
    } });
    var buffer: [256]u8 = undefined;
    _ = (try outbox.beginSend(&buffer)).?;
    var label = "agents".*;
    try outbox.pushRename(.{
        .request_id = @enumFromInt(2),
        .location = location,
        .label = &label,
    });
    @memset(&label, 'x');

    outbox.popSent();
    const decoded = try decodeClient_module((try outbox.beginSend(&buffer)).?);
    try std.testing.expectEqualStrings("agents", decoded.rename_tab.label);
    try std.testing.expectEqualDeep(location, decoded.rename_tab.location);
}

test "queued workspace creation owns name and cwd bytes until encoding" {
    var outbox: Outbox = .{};
    const pane_id: PaneIdType = @enumFromInt(1);
    try outbox.push(.{ .pane_resize = .{
        .pane_id = pane_id,
        .size = .{ .cols = 20, .rows = 10 },
    } });
    var buffer: [512]u8 = undefined;
    _ = (try outbox.beginSend(&buffer)).?;

    var name = "agents".*;
    var cwd = "/work/source".*;
    try outbox.pushCreateWorkspace(.{
        .request_id = @enumFromInt(2),
        .size = .{ .cols = 30, .rows = 12 },
        .name = &name,
        .launch = .{
            .cwd = &cwd,
            .cwd_source = pane_id,
            .arguments = &.{"/bin/sh"},
        },
    });
    @memset(&name, 'x');
    @memset(&cwd, 'y');

    outbox.popSent();
    const decoded = try decodeClient_module((try outbox.beginSend(&buffer)).?);
    try std.testing.expectEqualStrings("agents", decoded.create_workspace.name);
    try std.testing.expectEqualStrings("/work/source", decoded.create_workspace.launch.cwd);
    try std.testing.expectEqual(pane_id, decoded.create_workspace.launch.cwd_source.?);
}

test "queued tab creation owns label and cwd bytes until encoding" {
    var outbox: Outbox = .{};
    const pane_id: PaneIdType = @enumFromInt(1);
    try outbox.push(.{ .pane_resize = .{
        .pane_id = pane_id,
        .size = .{ .cols = 20, .rows = 10 },
    } });
    var buffer: [512]u8 = undefined;
    _ = (try outbox.beginSend(&buffer)).?;

    var label = "agents".*;
    var cwd = "/work/source".*;
    try outbox.pushCreateTab(.{
        .request_id = @enumFromInt(2),
        .workspace = .{ .workspace = @enumFromInt(3) },
        .label = &label,
        .size = .{ .cols = 30, .rows = 12 },
        .launch = .{
            .cwd = &cwd,
            .cwd_source = pane_id,
            .arguments = &.{"/bin/sh"},
        },
    });
    @memset(&label, 'x');
    @memset(&cwd, 'y');

    outbox.popSent();
    const decoded = try decodeClient_module((try outbox.beginSend(&buffer)).?);
    try std.testing.expectEqualStrings("agents", decoded.create_tab.label);
    try std.testing.expectEqualStrings("/work/source", decoded.create_tab.launch.cwd);
    try std.testing.expectEqual(pane_id, decoded.create_tab.launch.cwd_source.?);
}

test "pending launch cwd storage has an explicit bound" {
    var outbox: Outbox = .{};
    for (0..max_pending_launches) |index| try outbox.push(.{ .create_pane = .{
        .request_id = @enumFromInt(index + 1),
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        },
        .size = .{ .cols = 20, .rows = 10 },
        .launch = .{ .cwd = "/work", .arguments = &.{"/bin/sh"} },
    } });
    try std.testing.expectError(error.TooManyPendingLaunches, outbox.push(.{ .create_pane = .{
        .request_id = @enumFromInt(max_pending_launches + 1),
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        },
        .size = .{ .cols = 20, .rows = 10 },
        .launch = .{ .cwd = "/work", .arguments = &.{"/bin/sh"} },
    } }));
}

test "history replaces only unsent first-page queries" {
    var outbox: Outbox = .{};
    var query: OwnedHistoryQuery = .{ .request_id = @enumFromInt(1), .limit = 20 };
    try outbox.push(.{ .query_history = query });
    query.request_id = @enumFromInt(2);
    try outbox.push(.{ .query_history = query });
    try std.testing.expectEqual(@as(u8, 1), outbox.len);
    var buffer: [2048]u8 = undefined;
    const sent = (try decodeClient_module((try outbox.beginSend(&buffer)).?)).query_history;
    try std.testing.expectEqual(query.request_id, sent.request_id);

    query.request_id = @enumFromInt(3);
    try outbox.push(.{ .query_history = query });
    try std.testing.expectEqual(@as(u8, 2), outbox.len);
    query.offset = 20;
    try outbox.push(.{ .query_history = query });
    try std.testing.expectEqual(@as(u8, 3), outbox.len);
    query.offset = 0;
    query.entry_id = 7;
    try outbox.push(.{ .query_history = query });
    try std.testing.expectEqual(@as(u8, 4), outbox.len);
}

test "input never coalesces into a message already in flight" {
    var outbox: Outbox = .{};
    const pane_id: PaneIdType = @enumFromInt(1);
    try outbox.pushInput(pane_id, "first");
    var buffer: [64]u8 = undefined;
    var decoded = try decodeClient_module((try outbox.beginSend(&buffer)).?);
    try std.testing.expectEqualStrings("first", decoded.pane_input.bytes);
    try outbox.pushInput(pane_id, "second");
    try std.testing.expectEqual(@as(u8, 2), outbox.len);

    // A second claim while one is in flight yields nothing.
    try std.testing.expectEqual(@as(?[]const u8, null), try outbox.beginSend(&buffer));
    outbox.popSent();
    decoded = try decodeClient_module((try outbox.beginSend(&buffer)).?);
    try std.testing.expectEqualStrings("second", decoded.pane_input.bytes);
}

test "client layouts coalesce without mutating an in-flight snapshot" {
    var outbox: Outbox = .{};
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(3) },
        .tab_id = @enumFromInt(4),
    };
    const nodes = [_]ClientLayoutNodeType{.{ .pane = .{ .id = @enumFromInt(5) } }};
    const tabs = [_]ClientTabLayoutType{.{
        .location = location,
        .focused_pane = @enumFromInt(5),
        .fullscreen = false,
        .workspace_active = true,
        .nodes = &nodes,
    }};
    var update: ClientLayoutUpdateType = .{
        .sidebar_visible = true,
        .sidebar_width = 50,
        .workspace_list_collapsed = false,
        .active_tab = location,
        .tabs = &tabs,
    };

    try outbox.pushClientLayout(update);
    update.sidebar_width = 55;
    try outbox.pushClientLayout(update);
    try std.testing.expectEqual(@as(u8, 1), outbox.len);
    try std.testing.expectEqual(@as(u64, 1), outbox.stats.coalesced_client_layout);

    var buffer: [max_client_layout_wire_bytes_module]u8 = undefined;
    const first_payload = (try outbox.beginSend(&buffer)).?;
    const first = try decodeClient_module(first_payload);
    try std.testing.expect(first == .update_client_layout);
    try std.testing.expectEqual(@as(u16, 55), first.update_client_layout.sidebar_width);

    update.sidebar_width = 60;
    try outbox.pushClientLayout(update);
    update.sidebar_width = 65;
    try outbox.pushClientLayout(update);
    try std.testing.expectEqual(@as(u8, 2), outbox.len);
    try std.testing.expectEqual(@as(u64, 2), outbox.stats.coalesced_client_layout);
    try std.testing.expectEqual(@as(u16, 55), first.update_client_layout.sidebar_width);

    outbox.popSent();
    const second = try decodeClient_module((try outbox.beginSend(&buffer)).?);
    try std.testing.expect(second == .update_client_layout);
    try std.testing.expectEqual(@as(u16, 65), second.update_client_layout.sidebar_width);
    outbox.popSent();
    try std.testing.expectEqual(@as(u8, 0), outbox.len);
    try std.testing.expect(!outbox.client_layouts[0].used);
    try std.testing.expect(!outbox.client_layouts[1].used);
}

test "client layout folding never crosses an ordered request" {
    var outbox: Outbox = .{};
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(3) },
        .tab_id = @enumFromInt(4),
    };
    const pane_id: PaneIdType = @enumFromInt(5);
    const nodes = [_]ClientLayoutNodeType{.{ .pane = .{ .id = pane_id } }};
    const tabs = [_]ClientTabLayoutType{.{
        .location = location,
        .focused_pane = pane_id,
        .fullscreen = false,
        .workspace_active = true,
        .nodes = &nodes,
    }};
    const update: ClientLayoutUpdateType = .{
        .sidebar_visible = true,
        .sidebar_width = 50,
        .workspace_list_collapsed = false,
        .active_tab = location,
        .tabs = &tabs,
    };

    try outbox.pushClientLayout(update);
    try outbox.push(.{ .close_pane = .{
        .request_id = @enumFromInt(6),
        .pane_id = pane_id,
    } });
    try outbox.pushClientLayout(update);

    try std.testing.expectEqual(@as(u8, 3), outbox.len);
    try std.testing.expectEqual(@as(u64, 0), outbox.stats.coalesced_client_layout);
}

test "resize folding never crosses an ordered input message" {
    var outbox: Outbox = .{};
    const pane_id: PaneIdType = @enumFromInt(1);
    try outbox.push(.{ .pane_resize = .{
        .pane_id = pane_id,
        .size = .{ .cols = 20, .rows = 10 },
    } });
    try outbox.pushInput(pane_id, "x");
    try outbox.push(.{ .pane_resize = .{
        .pane_id = pane_id,
        .size = .{ .cols = 30, .rows = 12 },
    } });
    try std.testing.expectEqual(@as(u8, 3), outbox.len);
    try std.testing.expectEqual(@as(u64, 0), outbox.stats.coalesced_resize);
}

test "send completion releases its claim on success and failure" {
    var outbox: Outbox = .{};
    var buffer: [64]u8 = undefined;
    try outbox.push(.{ .detach_pane = .{ .pane_id = @enumFromInt(1) } });

    _ = (try outbox.beginSend(&buffer)).?;
    try std.testing.expectError(error.SocketFailed, outbox.finishSend(error.SocketFailed));
    try std.testing.expect(!outbox.inFlight());
    try std.testing.expectEqual(@as(u8, 1), outbox.len);

    _ = (try outbox.beginSend(&buffer)).?;
    try outbox.finishSend({});
    try std.testing.expect(!outbox.inFlight());
    try std.testing.expectEqual(@as(u8, 0), outbox.len);
}

test "a full outbox reports saturation" {
    var outbox: Outbox = .{};
    for (0..capacity) |index| try outbox.push(.{ .request_snapshot = .{
        .pane_id = @enumFromInt(index + 1),
        .known_frame_id = 0,
    } });
    try std.testing.expectError(error.ClientOutboxFull, outbox.push(.{ .detach_pane = .{
        .pane_id = @enumFromInt(1),
    } }));
    try std.testing.expectEqual(@as(u64, 1), outbox.stats.saturated);
}

test "queued tab creation owns argument bytes until encoding" {
    var outbox: Outbox = .{};
    const pane_id: PaneIdType = @enumFromInt(1);
    try outbox.push(.{ .pane_resize = .{
        .pane_id = pane_id,
        .size = .{ .cols = 20, .rows = 10 },
    } });
    var buffer: [512]u8 = undefined;
    _ = (try outbox.beginSend(&buffer)).?;

    var command = "lazygit".*;
    var flag = "-p".*;
    try outbox.pushCreateTab(.{
        .request_id = @enumFromInt(2),
        .workspace = .{ .workspace = @enumFromInt(3) },
        .label = "git",
        .size = .{ .cols = 30, .rows = 12 },
        .launch = .{
            .cwd = "/work/source",
            .cwd_source = pane_id,
            .arguments = &.{ &command, &flag },
        },
    });
    @memset(&command, 'x');
    @memset(&flag, 'y');

    outbox.popSent();
    const decoded = try decodeClient_module((try outbox.beginSend(&buffer)).?);
    try std.testing.expectEqual(@as(u16, 2), decoded.create_tab.launch.argument_count);
    var iterator = decoded.create_tab.launch.arguments();
    try std.testing.expectEqualStrings("lazygit", (try iterator.next()).?);
    try std.testing.expectEqualStrings("-p", (try iterator.next()).?);
}
