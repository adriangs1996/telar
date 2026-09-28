//! Bounded, allocation-free queue for messages sent by one frontend client.
//!
//! Variable input, creation labels, rename, notification, and launch-cwd bytes are copied
//! because their producers may reuse or replace their buffers as soon as the
//! event handler returns. One encoded buffer is borrowed only while a send
//! actor is active.
const data = @import("../model.zig");

const OwnedInput = @import("OwnedInput.zig");
const OwnedCreatePane = @import("OwnedCreatePane.zig");
const OwnedCreateTab = @import("OwnedCreateTab.zig");
const OwnedRename = @import("OwnedRename.zig");
const OwnedCreateWorkspace = @import("OwnedCreateWorkspace.zig");
const OwnedWorkspaceRename = @import("OwnedWorkspaceRename.zig");
const OwnedNotification = @import("OwnedNotification.zig");
const Outbox = @import("Outbox.zig");
const core = @import("telar-core");
const std = @import("std");

pub const capacity = core.max_panes_per_tab + 16;

/// Request groups permit at most one pane launch, one tab launch, and one
/// workspace launch at once. Keep one spare for bootstrap or recovery.
pub const max_pending_launches = 4;

pub const Message = union(enum) {
    query_change_review: u16,
    change_review_command: u16,
    open_editor: core.OpenEditor,
    open_pane: core.OpenPane,
    pane_input: OwnedInput,
    pane_resize: core.PaneResize,
    frame_ack: core.FrameAck,
    request_snapshot: core.RequestSnapshot,
    detach_pane: core.DetachPane,
    request_tab_snapshot: core.RequestTabSnapshot,
    create_pane: OwnedCreatePane,
    close_pane: core.ClosePane,
    request_workspace_snapshot: core.RequestWorkspaceSnapshot,
    create_tab: OwnedCreateTab,
    rename_tab: OwnedRename,
    close_tab: core.CloseTab,
    move_tab: core.MoveTab,
    request_graphics_snapshot: core.RequestGraphicsSnapshot,
    graphics_credit: core.GraphicsCredit,
    configure_graphics: core.ConfigureGraphics,
    configure_terminal_colors: core.TerminalColors,
    request_runtime_state: core.RequestRuntimeState,
    create_workspace: OwnedCreateWorkspace,
    rename_workspace: OwnedWorkspaceRename,
    set_pane_viewport: core.SetPaneViewport,
    copy_selection: core.CopySelection,
    show_notification: OwnedNotification,
    client_layout: u8,
    acknowledge_agent: core.AcknowledgeAgent,
    search_pane: data.OwnedSearch,
    query_history: data.OwnedHistoryQuery,
    delete_history: core.DeleteHistory,
    read_history_output: core.ReadHistoryOutput,
    suggest_command: data.OwnedSuggestion,
    complete_client_command: u16,
    /// Encoded `find_paths` length in the slot's payload.
    find_paths: u16,
    complete_pane_focus: core.CompletePaneFocus,
    /// A control request the client encoded itself into the item's payload:
    /// peek reads, prompts, interrupts and worktree launches.
    encoded: u16,
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
    var outbox: Outbox = try .init(std.testing.allocator);
    defer outbox.deinit(std.testing.allocator);
    try outbox.pushInput(@enumFromInt(1), "abc");
    try outbox.pushInput(@enumFromInt(1), "def");
    try std.testing.expectEqual(@as(u8, 1), outbox.len);
    try std.testing.expectEqual(@as(u64, 1), outbox.stats.coalesced_input);

    var buffer: [64]u8 = undefined;
    const decoded = try core.decodeClient((try outbox.beginSend(&buffer)).?);
    try std.testing.expectEqualStrings("abcdef", decoded.pane_input.bytes);
}

test "a long paste reserves all chunks before mutating the outbox" {
    var outbox: Outbox = try .init(std.testing.allocator);
    defer outbox.deinit(std.testing.allocator);
    const command = "x" ** (data.input_limits.max_encoded_bytes + 128);
    const pane_id: core.PaneId = @enumFromInt(1);
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
    var buffer: [data.input_limits.max_encoded_bytes + 64]u8 = undefined;
    var offset: usize = 0;
    while (try outbox.beginSend(&buffer)) |encoded| {
        const message = try core.decodeClient(encoded);
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

test "queued launches own cwd and transient editor arguments until encoding" {
    var outbox: Outbox = try .init(std.testing.allocator);
    defer outbox.deinit(std.testing.allocator);
    const pane_id: core.PaneId = @enumFromInt(1);
    try outbox.push(.{ .pane_resize = .{
        .pane_id = pane_id,
        .size = .{ .cols = 20, .rows = 10 },
    } });
    var buffer: [1024]u8 = undefined;
    _ = (try outbox.beginSend(&buffer)).?;

    var cwd = "/work/first".*;
    var path = ("/tmp/" ++ "a" ** 300 ++ ".md").*;
    var arguments = [_][]const u8{ "nvim", &path };
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
            .arguments = &arguments,
        },
    } });
    @memset(&path, 'x');
    arguments = .{ "bad", "bad" };
    @memset(&cwd, 'x');

    outbox.popSent();
    const decoded = try core.decodeClient((try outbox.beginSend(&buffer)).?);
    try std.testing.expectEqualStrings("/work/first", decoded.create_pane.launch.cwd);
    try std.testing.expectEqual(pane_id, decoded.create_pane.launch.cwd_source.?);
    var decoded_arguments = decoded.create_pane.launch.arguments();
    try std.testing.expectEqualStrings("nvim", (try decoded_arguments.next()).?);
    try std.testing.expectEqualStrings("/tmp/" ++ "a" ** 300 ++ ".md", (try decoded_arguments.next()).?);
}

test "queued tab rename owns bounded label bytes until encoding" {
    var outbox: Outbox = try .init(std.testing.allocator);
    defer outbox.deinit(std.testing.allocator);
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(3) },
        .tab_id = @enumFromInt(4),
    };
    const too_long = [_]u8{'x'} ** (core.max_tab_label_bytes + 1);

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
    const decoded = try core.decodeClient((try outbox.beginSend(&buffer)).?);
    try std.testing.expectEqualStrings("agents", decoded.rename_tab.label);
    try std.testing.expectEqualDeep(location, decoded.rename_tab.location);
}

test "queued workspace creation owns name and cwd bytes until encoding" {
    var outbox: Outbox = try .init(std.testing.allocator);
    defer outbox.deinit(std.testing.allocator);
    const pane_id: core.PaneId = @enumFromInt(1);
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
    const decoded = try core.decodeClient((try outbox.beginSend(&buffer)).?);
    try std.testing.expectEqualStrings("agents", decoded.create_workspace.name);
    try std.testing.expectEqualStrings("/work/source", decoded.create_workspace.launch.cwd);
    try std.testing.expectEqual(pane_id, decoded.create_workspace.launch.cwd_source.?);
}

test "workspace directory creation consent survives the queued wire request" {
    for ([_]bool{ false, true }) |confirmed| {
        var outbox: Outbox = try .init(std.testing.allocator);
        defer outbox.deinit(std.testing.allocator);
        try outbox.pushCreateWorkspace(.{ .request_id = @enumFromInt(2), .size = .{ .cols = 80, .rows = 24 }, .name = "agents", .launch = .{ .cwd = "/work/new-project", .arguments = &.{"/bin/sh"} }, .create_cwd = confirmed });
        var buffer: [512]u8 = undefined;
        const decoded = try core.decodeClient((try outbox.beginSend(&buffer)).?);
        try std.testing.expectEqual(confirmed, decoded.create_workspace.create_cwd);
        try std.testing.expectEqualStrings("/work/new-project", decoded.create_workspace.launch.cwd);
        try std.testing.expect(decoded.create_workspace.launch.cwd_source == null);
    }
}

test "queued tab creation owns label and cwd bytes until encoding" {
    var outbox: Outbox = try .init(std.testing.allocator);
    defer outbox.deinit(std.testing.allocator);
    const pane_id: core.PaneId = @enumFromInt(1);
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
    const decoded = try core.decodeClient((try outbox.beginSend(&buffer)).?);
    try std.testing.expectEqualStrings("agents", decoded.create_tab.label);
    try std.testing.expectEqualStrings("/work/source", decoded.create_tab.launch.cwd);
    try std.testing.expectEqual(pane_id, decoded.create_tab.launch.cwd_source.?);
}

test "pending launch cwd storage has an explicit bound" {
    var outbox: Outbox = try .init(std.testing.allocator);
    defer outbox.deinit(std.testing.allocator);
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
    var outbox: Outbox = try .init(std.testing.allocator);
    defer outbox.deinit(std.testing.allocator);
    var query: data.OwnedHistoryQuery = .{ .request_id = @enumFromInt(1), .limit = 20 };
    try outbox.push(.{ .query_history = query });
    query.request_id = @enumFromInt(2);
    try outbox.push(.{ .query_history = query });
    try std.testing.expectEqual(@as(u8, 1), outbox.len);
    var buffer: [2048]u8 = undefined;
    const sent = (try core.decodeClient((try outbox.beginSend(&buffer)).?)).query_history;
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
    var outbox: Outbox = try .init(std.testing.allocator);
    defer outbox.deinit(std.testing.allocator);
    const pane_id: core.PaneId = @enumFromInt(1);
    try outbox.pushInput(pane_id, "first");
    var buffer: [64]u8 = undefined;
    var decoded = try core.decodeClient((try outbox.beginSend(&buffer)).?);
    try std.testing.expectEqualStrings("first", decoded.pane_input.bytes);
    try outbox.pushInput(pane_id, "second");
    try std.testing.expectEqual(@as(u8, 2), outbox.len);

    // A second claim while one is in flight yields nothing.
    try std.testing.expectEqual(@as(?[]const u8, null), try outbox.beginSend(&buffer));
    outbox.popSent();
    decoded = try core.decodeClient((try outbox.beginSend(&buffer)).?);
    try std.testing.expectEqualStrings("second", decoded.pane_input.bytes);
}

test "client layouts coalesce without mutating an in-flight snapshot" {
    var outbox: Outbox = try .init(std.testing.allocator);
    defer outbox.deinit(std.testing.allocator);
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(3) },
        .tab_id = @enumFromInt(4),
    };
    const nodes = [_]core.ClientLayoutNode{.{ .pane = .{ .id = @enumFromInt(5) } }};
    const tabs = [_]core.ClientTabLayout{.{
        .location = location,
        .focused_pane = @enumFromInt(5),
        .fullscreen = false,
        .workspace_active = true,
        .nodes = &nodes,
    }};
    var update: core.ClientLayoutUpdate = .{
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

    var buffer: [core.max_client_layout_wire_bytes]u8 = undefined;
    const first_payload = (try outbox.beginSend(&buffer)).?;
    const first = try core.decodeClient(first_payload);
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
    const second = try core.decodeClient((try outbox.beginSend(&buffer)).?);
    try std.testing.expect(second == .update_client_layout);
    try std.testing.expectEqual(@as(u16, 65), second.update_client_layout.sidebar_width);
    outbox.popSent();
    try std.testing.expectEqual(@as(u8, 0), outbox.len);
    try std.testing.expect(!outbox.client_layouts[0].used);
    try std.testing.expect(!outbox.client_layouts[1].used);
}

test "client layout folding never crosses an ordered request" {
    var outbox: Outbox = try .init(std.testing.allocator);
    defer outbox.deinit(std.testing.allocator);
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(3) },
        .tab_id = @enumFromInt(4),
    };
    const pane_id: core.PaneId = @enumFromInt(5);
    const nodes = [_]core.ClientLayoutNode{.{ .pane = .{ .id = pane_id } }};
    const tabs = [_]core.ClientTabLayout{.{
        .location = location,
        .focused_pane = pane_id,
        .fullscreen = false,
        .workspace_active = true,
        .nodes = &nodes,
    }};
    const update: core.ClientLayoutUpdate = .{
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
    var outbox: Outbox = try .init(std.testing.allocator);
    defer outbox.deinit(std.testing.allocator);
    const pane_id: core.PaneId = @enumFromInt(1);
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
    var outbox: Outbox = try .init(std.testing.allocator);
    defer outbox.deinit(std.testing.allocator);
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
    var outbox: Outbox = try .init(std.testing.allocator);
    defer outbox.deinit(std.testing.allocator);
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
    var outbox: Outbox = try .init(std.testing.allocator);
    defer outbox.deinit(std.testing.allocator);
    const pane_id: core.PaneId = @enumFromInt(1);
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
    const decoded = try core.decodeClient((try outbox.beginSend(&buffer)).?);
    try std.testing.expectEqual(@as(u16, 2), decoded.create_tab.launch.argument_count);
    var iterator = decoded.create_tab.launch.arguments();
    try std.testing.expectEqualStrings("lazygit", (try iterator.next()).?);
    try std.testing.expectEqualStrings("-p", (try iterator.next()).?);
}

test "routed completions retain their text through send and recycle bounded slots" {
    var outbox: Outbox = try .init(std.testing.allocator);
    defer outbox.deinit(std.testing.allocator);
    var reply: core.ClientCommand = .{ .request_id = @enumFromInt(5), .route = .{ .id = 7, .generation = 9 }, .action = .workspace_select, .status = .admitted, .target_id = 42 };
    try reply.setText("retained");
    for (0..capacity) |_| {
        try outbox.pushClientCompletion(reply);
    }

    try std.testing.expectError(error.ClientOutboxFull, outbox.pushClientCompletion(reply));
    try reply.setText("reused input");
    var buffer: [core.ClientCommand.capacity + 64]u8 = undefined;
    const decoded = try core.decodeClient((try outbox.beginSend(&buffer)).?);
    try std.testing.expectEqualStrings("retained", decoded.complete_client_command.text());
    try outbox.finishSend({});
    try outbox.pushClientCompletion(reply);
    try std.testing.expect(@sizeOf(Message) < 512);
}

test "rejected editor argv releases its queue and launch slots" {
    var outbox: Outbox = try .init(std.testing.allocator);
    defer outbox.deinit(std.testing.allocator);
    const oversized = [_]u8{'x'} ** (data.input_limits.max_encoded_bytes + 1);
    for (0..max_pending_launches + 1) |_| {
        try std.testing.expectError(error.InvalidArguments, outbox.push(.{ .create_pane = .{
            .request_id = @enumFromInt(2),
            .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) },
            .size = .{ .cols = 20, .rows = 10 },
            .launch = .{ .cwd = "/tmp", .arguments = &.{ "nvim", &oversized } },
        } }));
        try std.testing.expectEqual(@as(u8, 0), outbox.len);
    }

    try outbox.push(.{ .create_pane = .{
        .request_id = @enumFromInt(3),
        .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) },
        .size = .{ .cols = 20, .rows = 10 },
        .launch = .{ .cwd = "/tmp", .arguments = &.{ "nvim", "/tmp/design.md" } },
    } });
    var buffer: [256]u8 = undefined;
    const request = (try core.decodeClient((try outbox.beginSend(&buffer)).?)).create_pane;
    try std.testing.expectEqual(@as(u64, 3), @intFromEnum(request.request_id));
    try outbox.finishSend({});
}

test "queued editor tabs retain long arguments after configuration source storage is reused" {
    var outbox: Outbox = try .init(std.testing.allocator);
    defer outbox.deinit(std.testing.allocator);
    var executable = ("/opt/" ++ "editor" ** 50).*;
    var path = "/tmp/design.md".*;
    var arguments = [_][]const u8{ &executable, &path };
    try outbox.pushCreateTab(.{
        .request_id = @enumFromInt(2),
        .workspace = .{ .workspace = @enumFromInt(1) },
        .label = "editor",
        .size = .{ .cols = 20, .rows = 10 },
        .launch = .{ .cwd = "/tmp", .arguments = &arguments },
    });
    @memset(&executable, 'x');
    @memset(&path, 'x');
    arguments = .{ "bad", "bad" };

    var buffer: [1024]u8 = undefined;
    const request = (try core.decodeClient((try outbox.beginSend(&buffer)).?)).create_tab;
    var argv = request.launch.arguments();
    try std.testing.expectEqualStrings("/opt/" ++ "editor" ** 50, (try argv.next()).?);
    try std.testing.expectEqualStrings("/tmp/design.md", (try argv.next()).?);
    try outbox.finishSend({});
}

test "change review outbox owns range comment bytes and rejects overflow atomically" {
    var outbox: Outbox = try .init(std.testing.allocator);
    defer outbox.deinit(std.testing.allocator);
    var path = "src/main.zig".*;
    var body = "Preserve café on these lines".*;
    const request: core.ChangeReviewCommand = .{ .request_id = @enumFromInt(21), .pane_id = @enumFromInt(2), .pane_generation = 3, .edition_id = 7, .expected_revision = 4, .action = .save_comment, .path = &path, .first_line = 3, .last_line = 6, .body = &body, .draft = true };
    try outbox.pushChangeReviewCommand(request);
    @memset(&path, 'x');
    @memset(&body, 'x');
    var encoded: [data.input_limits.max_encoded_bytes]u8 = undefined;
    const sent = (try outbox.beginSend(&encoded)).?;
    const decoded = try core.decodeClient(sent);
    try std.testing.expectEqualStrings("src/main.zig", decoded.change_review_command.path);
    try std.testing.expectEqualStrings("Preserve café on these lines", decoded.change_review_command.body);
    try std.testing.expectEqual(@as(u32, 6), decoded.change_review_command.last_line);
    try std.testing.expectEqual(@as(u64, 4), decoded.change_review_command.expected_revision);
    outbox.sendFailed();
    const before = outbox.len;
    var invalid = request;
    var huge: [core.change_review.max_comment_bytes + 1]u8 = @splat('a');
    invalid.body = &huge;
    try std.testing.expectError(error.InvalidChangeReview, outbox.pushChangeReviewCommand(invalid));
    try std.testing.expectEqual(before, outbox.len);
    const retry = (try outbox.beginSend(&encoded)).?;
    try std.testing.expectEqualStrings("Preserve café on these lines", (try core.decodeClient(retry)).change_review_command.body);
}

test "change review query owns its provider conversation identity" {
    var outbox: Outbox = try .init(std.testing.allocator);
    defer outbox.deinit(std.testing.allocator);
    var conversation = "thread-A".*;
    try outbox.pushChangeReviewQuery(.{ .request_id = @enumFromInt(21), .pane_id = @enumFromInt(2), .pane_generation = 3, .edition_id = 7, .session = &conversation });
    @memset(&conversation, 'x');
    var bytes: [data.input_limits.max_encoded_bytes]u8 = undefined;
    const sent = (try outbox.beginSend(&bytes)).?;
    try std.testing.expectEqualStrings("thread-A", (try core.decodeClient(sent)).query_change_review.session);
}

test "queued editor requests own paths without enlarging queue metadata" {
    var outbox: Outbox = try .init(std.testing.allocator);
    defer outbox.deinit(std.testing.allocator);
    var editor = "nvim".*;
    var path = "/tmp/original file".*;
    try outbox.push(.{ .open_editor = .{
        .request_id = @enumFromInt(1),
        .pane_id = @enumFromInt(2),
        .pane_generation = 3,
        .editor = &editor,
        .path = &path,
    } });
    @memset(&editor, 'x');
    @memset(&path, 'x');
    var buffer: [256]u8 = undefined;
    const request = (try core.decodeClient((try outbox.beginSend(&buffer)).?)).open_editor;
    try std.testing.expectEqualStrings("nvim", request.editor);
    try std.testing.expectEqualStrings("/tmp/original file", request.path);
    try std.testing.expect(@sizeOf(Message) < 512);
    try std.testing.expect(@sizeOf(Outbox) < 720 * 1024);
}
