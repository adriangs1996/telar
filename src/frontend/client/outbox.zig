//! Bounded, allocation-free queue for messages sent by one frontend client.
//!
//! Variable input and rename bytes are copied because their producers reuse
//! their buffers as soon as the event handler returns. Launch slices remain
//! borrowed from the immutable client options, whose lifetime covers the
//! outbox. One encoded buffer is borrowed only while a send actor is active.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;

pub const capacity = schema.max_panes_per_tab + 16;
pub const max_input_bytes = 8 * 1024;

const OwnedInput = struct {
    pane_id: schema.PaneId,
    len: u16,
};

const OwnedRename = struct {
    request_id: schema.RequestId,
    location: schema.TabLocation,
    label: [schema.max_tab_label_bytes]u8 = undefined,
    len: u8,

    fn slice(rename: *const OwnedRename) []const u8 {
        return rename.label[0..rename.len];
    }
};

const OwnedWorkspaceRename = struct {
    request_id: schema.RequestId,
    workspace: schema.WorkspaceLocation,
    name: [schema.max_tab_label_bytes]u8 = undefined,
    len: u8,

    fn slice(rename: *const OwnedWorkspaceRename) []const u8 {
        return rename.name[0..rename.len];
    }
};

const OwnedNotification = struct {
    request_id: schema.RequestId,
    level: schema.NotificationLevel,
    duration_ms: u32,
    target: schema.NotificationTarget,
    title: [schema.max_notification_title_bytes]u8 = undefined,
    title_len: u8,
    message: [schema.max_notification_message_bytes]u8 = undefined,
    message_len: u8,

    fn view(value: *const OwnedNotification) schema.ShowNotification {
        return .{
            .request_id = value.request_id,
            .notification = .{
                .level = value.level,
                .duration_ms = value.duration_ms,
                .target = value.target,
                .title = value.title[0..value.title_len],
                .message = value.message[0..value.message_len],
            },
        };
    }
};

pub const Message = union(enum) {
    open_pane: schema.OpenPane,
    pane_input: OwnedInput,
    pane_resize: schema.PaneResize,
    frame_ack: schema.FrameAck,
    request_snapshot: schema.RequestSnapshot,
    detach_pane: schema.DetachPane,
    request_tab_snapshot: schema.RequestTabSnapshot,
    create_pane: schema.CreatePane,
    close_pane: schema.ClosePane,
    request_workspace_snapshot: schema.RequestWorkspaceSnapshot,
    create_tab: schema.CreateTab,
    rename_tab: OwnedRename,
    close_tab: schema.CloseTab,
    move_tab: schema.MoveTab,
    request_graphics_snapshot: schema.RequestGraphicsSnapshot,
    graphics_credit: schema.GraphicsCredit,
    configure_graphics: schema.ConfigureGraphics,
    create_workspace: schema.CreateWorkspace,
    rename_workspace: OwnedWorkspaceRename,
    set_pane_viewport: schema.SetPaneViewport,
    copy_selection: schema.CopySelection,
    show_notification: OwnedNotification,
};

pub const Stats = struct {
    high_water: u8 = 0,
    saturated: u64 = 0,
    coalesced_input: u64 = 0,
    coalesced_resize: u64 = 0,
    coalesced_ack: u64 = 0,
};

pub const Outbox = struct {
    items: [capacity]Message = undefined,
    input_bytes: [capacity][max_input_bytes]u8 = undefined,
    head: u8 = 0,
    len: u8 = 0,
    send_pending: bool = false,
    stats: Stats = .{},

    pub fn hasCapacity(outbox: *const Outbox) bool {
        return outbox.len < capacity;
    }

    pub fn canQueueInput(outbox: *const Outbox) bool {
        return outbox.hasCapacity();
    }

    pub fn push(outbox: *Outbox, message: Message) !void {
        switch (message) {
            .pane_resize => |resize| return outbox.pushResize(resize),
            .frame_ack => |ack| return outbox.pushAck(ack),
            .pane_input, .rename_tab, .rename_workspace, .show_notification => unreachable,
            else => {},
        }
        try outbox.append(message);
    }

    pub fn pushInput(outbox: *Outbox, pane_id: schema.PaneId, bytes: []const u8) !void {
        if (bytes.len == 0 or bytes.len > max_input_bytes)
            return error.InvalidInputLength;
        if (outbox.mutableTailIndex()) |index| switch (outbox.items[index]) {
            .pane_input => |*input| {
                if (input.pane_id == pane_id and
                    bytes.len <= outbox.input_bytes[index].len - input.len)
                {
                    @memcpy(outbox.input_bytes[index][input.len..][0..bytes.len], bytes);
                    input.len += @intCast(bytes.len);
                    outbox.stats.coalesced_input +|= 1;
                    return;
                }
            },
            else => {},
        };
        const index = try outbox.reserve();
        outbox.items[index] = .{ .pane_input = .{
            .pane_id = pane_id,
            .len = @intCast(bytes.len),
        } };
        @memcpy(outbox.input_bytes[index][0..bytes.len], bytes);
    }

    pub fn pushRename(outbox: *Outbox, rename: schema.RenameTab) !void {
        if (rename.label.len == 0 or rename.label.len > schema.max_tab_label_bytes)
            return error.InvalidTabLabel;
        var owned: OwnedRename = .{
            .request_id = rename.request_id,
            .location = rename.location,
            .len = @intCast(rename.label.len),
        };
        @memcpy(owned.label[0..rename.label.len], rename.label);
        try outbox.append(.{ .rename_tab = owned });
    }

    pub fn pushWorkspaceRename(outbox: *Outbox, rename: schema.RenameWorkspace) !void {
        if (rename.name.len == 0 or rename.name.len > schema.max_tab_label_bytes)
            return error.InvalidWorkspaceName;
        var owned: OwnedWorkspaceRename = .{
            .request_id = rename.request_id,
            .workspace = rename.workspace,
            .len = @intCast(rename.name.len),
        };
        @memcpy(owned.name[0..rename.name.len], rename.name);
        try outbox.append(.{ .rename_workspace = owned });
    }

    pub fn pushNotification(outbox: *Outbox, request: schema.ShowNotification) !void {
        if (request.notification.title.len > schema.max_notification_title_bytes or
            request.notification.message.len > schema.max_notification_message_bytes)
            return error.NotificationTooLarge;
        var owned: OwnedNotification = .{
            .request_id = request.request_id,
            .level = request.notification.level,
            .duration_ms = request.notification.duration_ms,
            .target = request.notification.target,
            .title_len = @intCast(request.notification.title.len),
            .message_len = @intCast(request.notification.message.len),
        };
        @memcpy(owned.title[0..request.notification.title.len], request.notification.title);
        @memcpy(owned.message[0..request.notification.message.len], request.notification.message);
        try outbox.append(.{ .show_notification = owned });
    }

    pub fn peek(outbox: *const Outbox) ?*const Message {
        if (outbox.len == 0) return null;
        return &outbox.items[outbox.head];
    }

    pub fn popSent(outbox: *Outbox) void {
        std.debug.assert(outbox.send_pending);
        std.debug.assert(outbox.len != 0);
        outbox.send_pending = false;
        outbox.head = @intCast((@as(usize, outbox.head) + 1) % capacity);
        outbox.len -= 1;
    }

    pub fn encodeNext(outbox: *const Outbox, buffer: []u8) ![]const u8 {
        const message = outbox.peek() orelse return error.OutboxEmpty;
        return switch (message.*) {
            .open_pane => |value| schema.encodeOpenPane(buffer, value),
            .pane_input => |value| schema.encodePaneInput(buffer, .{
                .pane_id = value.pane_id,
                .bytes = outbox.input_bytes[outbox.head][0..value.len],
            }),
            .pane_resize => |value| schema.encodePaneResize(buffer, value),
            .frame_ack => |value| schema.encodeFrameAck(buffer, value),
            .request_snapshot => |value| schema.encodeRequestSnapshot(buffer, value),
            .detach_pane => |value| schema.encodeDetachPane(buffer, value),
            .request_tab_snapshot => |value| schema.encodeRequestTabSnapshot(buffer, value),
            .create_pane => |value| schema.encodeCreatePane(buffer, value),
            .close_pane => |value| schema.encodeClosePane(buffer, value),
            .request_workspace_snapshot => |value| schema.encodeRequestWorkspaceSnapshot(buffer, value),
            .create_tab => |value| schema.encodeCreateTab(buffer, value),
            .rename_tab => |*value| schema.encodeRenameTab(buffer, .{
                .request_id = value.request_id,
                .location = value.location,
                .label = value.slice(),
            }),
            .close_tab => |value| schema.encodeCloseTab(buffer, value),
            .move_tab => |value| schema.encodeMoveTab(buffer, value),
            .request_graphics_snapshot => |value| schema.encodeRequestGraphicsSnapshot(buffer, value),
            .graphics_credit => |value| schema.encodeGraphicsCredit(buffer, value),
            .configure_graphics => |value| schema.encodeConfigureGraphics(buffer, value),
            .create_workspace => |value| schema.encodeCreateWorkspace(buffer, value),
            .rename_workspace => |*value| schema.encodeRenameWorkspace(buffer, .{
                .request_id = value.request_id,
                .workspace = value.workspace,
                .name = value.slice(),
            }),
            .set_pane_viewport => |value| schema.encodeSetPaneViewport(buffer, value),
            .copy_selection => |value| schema.encodeCopySelection(buffer, value),
            .show_notification => |*value| schema.encodeShowNotification(buffer, value.view()),
        };
    }

    fn append(outbox: *Outbox, message: Message) !void {
        const index = try outbox.reserve();
        outbox.items[index] = message;
    }

    fn reserve(outbox: *Outbox) !usize {
        if (outbox.len == capacity) {
            outbox.stats.saturated +|= 1;
            return error.ClientOutboxFull;
        }
        const index = (@as(usize, outbox.head) + outbox.len) % capacity;
        outbox.len += 1;
        outbox.stats.high_water = @max(outbox.stats.high_water, outbox.len);
        return index;
    }

    fn tailIndex(outbox: *const Outbox) ?usize {
        if (outbox.len == 0) return null;
        return (@as(usize, outbox.head) + outbox.len - 1) % capacity;
    }

    fn mutableTailIndex(outbox: *const Outbox) ?usize {
        const index = outbox.tailIndex() orelse return null;
        if (outbox.send_pending and index == outbox.head) return null;
        return index;
    }

    fn pushResize(outbox: *Outbox, resize: schema.PaneResize) !void {
        var offset: usize = 0;
        const mutable_len = outbox.len - @intFromBool(outbox.send_pending);
        while (offset < mutable_len) : (offset += 1) {
            const index = (@as(usize, outbox.head) + outbox.len - 1 - offset) % capacity;
            switch (outbox.items[index]) {
                .pane_resize => |*pending| {
                    if (pending.pane_id == resize.pane_id) {
                        pending.* = resize;
                        outbox.stats.coalesced_resize +|= 1;
                        return;
                    }
                },
                else => break,
            }
        }
        try outbox.append(.{ .pane_resize = resize });
    }

    fn pushAck(outbox: *Outbox, ack: schema.FrameAck) !void {
        var offset: usize = 0;
        const mutable_len = outbox.len - @intFromBool(outbox.send_pending);
        while (offset < mutable_len) : (offset += 1) {
            const index = (@as(usize, outbox.head) + outbox.len - 1 - offset) % capacity;
            switch (outbox.items[index]) {
                .frame_ack => |*pending| {
                    if (pending.pane_id == ack.pane_id) {
                        pending.* = ack;
                        outbox.stats.coalesced_ack +|= 1;
                        return;
                    }
                },
                else => break,
            }
        }
        try outbox.append(.{ .frame_ack = ack });
    }
};

test "adjacent input for one pane is folded without allocation" {
    var outbox: Outbox = .{};
    try outbox.pushInput(@enumFromInt(1), "abc");
    try outbox.pushInput(@enumFromInt(1), "def");
    try std.testing.expectEqual(@as(u8, 1), outbox.len);
    try std.testing.expectEqual(@as(u64, 1), outbox.stats.coalesced_input);

    var buffer: [64]u8 = undefined;
    const decoded = try schema.decodeClient(try outbox.encodeNext(&buffer));
    try std.testing.expectEqualStrings("abcdef", decoded.pane_input.bytes);
}

test "queue metadata stays small when input storage grows" {
    try std.testing.expect(@sizeOf(Message) < 512);
    try std.testing.expect(@sizeOf(Outbox) < 700 * 1024);
}

test "input never coalesces into a message already in flight" {
    var outbox: Outbox = .{};
    const pane_id: schema.PaneId = @enumFromInt(1);
    try outbox.pushInput(pane_id, "first");
    outbox.send_pending = true;
    try outbox.pushInput(pane_id, "second");
    try std.testing.expectEqual(@as(u8, 2), outbox.len);

    var buffer: [64]u8 = undefined;
    var decoded = try schema.decodeClient(try outbox.encodeNext(&buffer));
    try std.testing.expectEqualStrings("first", decoded.pane_input.bytes);
    outbox.popSent();
    decoded = try schema.decodeClient(try outbox.encodeNext(&buffer));
    try std.testing.expectEqualStrings("second", decoded.pane_input.bytes);
}

test "resize folding never crosses an ordered input message" {
    var outbox: Outbox = .{};
    const pane_id: schema.PaneId = @enumFromInt(1);
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
