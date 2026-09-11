const Outbox = @This();
const source_namespace = @import("outbox_support.zig");
const OwnedLaunchCwd = @import("OwnedLaunchCwd.zig");
const OwnedClientLayout = @import("OwnedClientLayout.zig");
const Stats = @import("Stats.zig");
const Snapshot = @import("Snapshot.zig");
const OwnedRename = @import("OwnedRename.zig");
const OwnedWorkspaceRename = @import("OwnedWorkspaceRename.zig");
const OwnedCreateWorkspace = @import("OwnedCreateWorkspace.zig");
const OwnedCreateTab = @import("OwnedCreateTab.zig");
const OwnedNotification = @import("OwnedNotification.zig");
const std = @import("std");
items: [source_namespace.capacity]source_namespace.Message = undefined,
input_bytes: [source_namespace.capacity][source_namespace.max_input_bytes]u8 = undefined,
launch_cwds: [source_namespace.max_pending_launches]OwnedLaunchCwd =
    [_]OwnedLaunchCwd{.{}} ** source_namespace.max_pending_launches,
client_layouts: [2]OwnedClientLayout = [_]OwnedClientLayout{.{}} ** 2,
item_launch_cwd: [source_namespace.capacity]?u8 = @splat(null),
head: u8 = 0,
len: u8 = 0,
send_pending: bool = false,
stats: Stats = .{},

pub fn hasCapacity(outbox: *const Outbox) bool {
    return outbox.len < source_namespace.capacity;
}

/// Reports how many complete messages the bounded queue can still own.
///
/// ```zig
/// const available = outbox.availableCapacity();
/// ```
pub fn availableCapacity(outbox: *const Outbox) usize {
    return source_namespace.capacity - @as(usize, outbox.len);
}

/// Copies the stable counters needed by client telemetry.
///
/// ```zig
/// const snapshot = outbox.snapshot();
/// ```
pub fn snapshot(outbox: *const Outbox) Snapshot {
    return .{
        .depth = outbox.len,
        .high_water = outbox.stats.high_water,
        .saturated = outbox.stats.saturated,
        .coalesced_input = outbox.stats.coalesced_input,
        .coalesced_resize = outbox.stats.coalesced_resize,
        .coalesced_ack = outbox.stats.coalesced_ack,
        .coalesced_client_layout = outbox.stats.coalesced_client_layout,
    };
}

pub fn push(outbox: *Outbox, message: source_namespace.Message) !void {
    switch (message) {
        .pane_resize => |resize| return outbox.pushResize(resize),
        .frame_ack => |ack| return outbox.pushAck(ack),
        .query_history => |query| {
            if (query.offset == 0 and query.snapshot_id == 0 and query.entry_id == 0) {
                if (outbox.mutableTailIndex()) |index| {
                    switch (outbox.items[index]) {
                        .query_history => |old| {
                            if (old.offset == 0 and old.snapshot_id == 0 and old.entry_id == 0) {
                                outbox.items[index] = message;
                                return;
                            }
                        },
                        else => {},
                    }
                }
            }
        },
        .pane_input, .create_tab, .create_workspace, .rename_tab, .rename_workspace, .show_notification, .client_layout => unreachable,
        else => {},
    }
    try outbox.append(message);
}

pub fn pushInput(outbox: *Outbox, pane_id: source_namespace.schema.PaneId, bytes: []const u8) !void {
    if (bytes.len == 0 or bytes.len > source_namespace.max_input_bytes) {
        return error.InvalidInputLength;
    }
    if (outbox.mutableTailIndex()) |index| {
        switch (outbox.items[index]) {
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
        }
    }
    const index = try outbox.reserve();
    outbox.item_launch_cwd[index] = null;
    outbox.items[index] = .{ .pane_input = .{
        .pane_id = pane_id,
        .len = @intCast(bytes.len),
    } };
    @memcpy(outbox.input_bytes[index][0..bytes.len], bytes);
}

/// Reserves a whole bounded paste before copying any chunk into the queue.
/// Example: `try outbox.pushInputBatch(pane_id, encoded_paste);`.
pub fn pushInputBatch(outbox: *Outbox, pane_id: source_namespace.schema.PaneId, bytes: []const u8) !void {
    if (bytes.len == 0 or bytes.len > source_namespace.schema.max_history_command_bytes + 13) {
        return error.InvalidInputLength;
    }

    const count = (bytes.len + source_namespace.max_input_bytes - 1) / source_namespace.max_input_bytes;
    if (outbox.availableCapacity() < count) {
        return error.ClientOutboxFull;
    }

    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + source_namespace.max_input_bytes, bytes.len);
        try outbox.pushInput(pane_id, bytes[offset..end]);
        offset = end;
    }
}

pub fn pushRename(outbox: *Outbox, rename: source_namespace.schema.RenameTab) !void {
    if (rename.label.len == 0 or rename.label.len > source_namespace.schema.max_tab_label_bytes) {
        return error.InvalidTabLabel;
    }

    var owned: OwnedRename = .{
        .request_id = rename.request_id,
        .location = rename.location,
        .len = @intCast(rename.label.len),
    };
    @memcpy(owned.label[0..rename.label.len], rename.label);
    try outbox.append(.{ .rename_tab = owned });
}

pub fn pushWorkspaceRename(outbox: *Outbox, rename: source_namespace.schema.RenameWorkspace) !void {
    if (rename.name.len == 0 or rename.name.len > source_namespace.schema.max_tab_label_bytes) {
        return error.InvalidWorkspaceName;
    }
    var owned: OwnedWorkspaceRename = .{
        .request_id = rename.request_id,
        .workspace = rename.workspace,
        .len = @intCast(rename.name.len),
    };
    @memcpy(owned.name[0..rename.name.len], rename.name);
    try outbox.append(.{ .rename_workspace = owned });
}

pub fn pushCreateWorkspace(outbox: *Outbox, request: source_namespace.schema.CreateWorkspace) !void {
    if (request.name.len == 0 or request.name.len > source_namespace.schema.max_tab_label_bytes) {
        return error.InvalidWorkspaceName;
    }

    var owned: OwnedCreateWorkspace = .{
        .request_id = request.request_id,
        .size = request.size,
        .name_len = @intCast(request.name.len),
        .launch = request.launch,
    };
    @memcpy(owned.name[0..request.name.len], request.name);
    try outbox.append(.{ .create_workspace = owned });
}

pub fn pushCreateTab(outbox: *Outbox, request: source_namespace.schema.CreateTab) !void {
    if (request.label.len > source_namespace.schema.max_tab_label_bytes) {
        return error.InvalidTabLabel;
    }

    var owned: OwnedCreateTab = .{
        .request_id = request.request_id,
        .workspace = request.workspace,
        .label_len = @intCast(request.label.len),
        .size = request.size,
        .launch = request.launch,
    };
    @memcpy(owned.label[0..request.label.len], request.label);
    _ = owned.ownArguments(request.launch.arguments);
    try outbox.append(.{ .create_tab = owned });
}

pub fn pushNotification(outbox: *Outbox, request: source_namespace.schema.ShowNotification) !void {
    if (request.notification.title.len > source_namespace.schema.max_notification_title_bytes or
        request.notification.message.len > source_namespace.schema.max_notification_message_bytes)
    {
        return error.NotificationTooLarge;
    }
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

/// Encodes and coalesces the latest complete client layout without
/// retaining slices into the mutable model.
///
/// ```zig
/// try outbox.pushClientLayout(update);
/// ```
pub fn pushClientLayout(outbox: *Outbox, update: source_namespace.schema.ClientLayoutUpdate) !void {
    var offset: usize = 0;
    const mutable_len = outbox.len - @intFromBool(outbox.send_pending);
    while (offset < mutable_len) : (offset += 1) {
        const index = (@as(usize, outbox.head) + outbox.len - 1 - offset) % source_namespace.capacity;
        switch (outbox.items[index]) {
            .client_layout => |slot_index| {
                const slot = &outbox.client_layouts[slot_index];
                var scratch: [source_namespace.schema.max_client_layout_wire_bytes]u8 = undefined;
                const encoded = try source_namespace.schema.encodeClientLayoutUpdate(&scratch, update);
                @memcpy(slot.bytes[0..encoded.len], encoded);
                slot.len = @intCast(encoded.len);
                outbox.stats.coalesced_client_layout +|= 1;
                return;
            },
            else => break,
        }
    }

    const slot_index = try outbox.claimClientLayout(update);
    errdefer outbox.releaseClientLayoutSlot(slot_index);
    try outbox.append(.{ .client_layout = slot_index });
}

pub fn peek(outbox: *const Outbox) ?*const source_namespace.Message {
    if (outbox.len == 0) {
        return null;
    }
    return &outbox.items[outbox.head];
}

/// Claims the next queued message: encodes it into `buffer` and marks
/// the send in flight. Null while a send is already in flight or the
/// queue is empty. The claim ends in exactly one of `popSent` (the
/// scheduler delivered it) or `sendFailed` (it never left).
pub fn beginSend(outbox: *Outbox, buffer: []u8) !?[]const u8 {
    if (outbox.send_pending or outbox.len == 0) {
        return null;
    }
    const payload = try outbox.encodeNext(buffer);
    outbox.send_pending = true;
    return payload;
}

/// The scheduler refused the claimed send; the message stays queued.
pub fn sendFailed(outbox: *Outbox) void {
    std.debug.assert(outbox.send_pending);
    outbox.send_pending = false;
}

/// Releases one completed send claim. A failed socket write retains the
/// queued message for terminal cleanup and propagates its error.
///
/// ```zig
/// try outbox.finishSend(result);
/// ```
pub fn finishSend(outbox: *Outbox, result: anyerror!void) !void {
    result catch |err| {
        outbox.sendFailed();

        return err;
    };

    outbox.popSent();
}

/// True while a claimed send has neither completed nor failed.
pub fn inFlight(outbox: *const Outbox) bool {
    return outbox.send_pending;
}

pub fn popSent(outbox: *Outbox) void {
    std.debug.assert(outbox.send_pending);
    std.debug.assert(outbox.len != 0);
    outbox.releaseLaunchCwd(outbox.head);
    outbox.releaseClientLayout(outbox.head);
    outbox.send_pending = false;
    outbox.head = @intCast((@as(usize, outbox.head) + 1) % source_namespace.capacity);
    outbox.len -= 1;
}

fn encodeNext(outbox: *const Outbox, buffer: []u8) ![]const u8 {
    const message = outbox.peek() orelse return error.OutboxEmpty;
    return switch (message.*) {
        .open_pane => |value| {
            var owned = value;
            if (owned.launch) |*launch| {
                launch.cwd = outbox.launchCwd(outbox.head);
            }
            return source_namespace.schema.encodeOpenPane(buffer, owned);
        },
        .pane_input => |value| source_namespace.schema.encodePaneInput(buffer, .{
            .pane_id = value.pane_id,
            .bytes = outbox.input_bytes[outbox.head][0..value.len],
        }),
        .pane_resize => |value| source_namespace.schema.encodePaneResize(buffer, value),
        .frame_ack => |value| source_namespace.schema.encodeFrameAck(buffer, value),
        .request_snapshot => |value| source_namespace.schema.encodeRequestSnapshot(buffer, value),
        .detach_pane => |value| source_namespace.schema.encodeDetachPane(buffer, value),
        .request_tab_snapshot => |value| source_namespace.schema.encodeRequestTabSnapshot(buffer, value),
        .create_pane => |value| {
            var owned = value;
            owned.launch.cwd = outbox.launchCwd(outbox.head);
            return source_namespace.schema.encodeCreatePane(buffer, owned);
        },
        .close_pane => |value| source_namespace.schema.encodeClosePane(buffer, value),
        .request_workspace_snapshot => |value| source_namespace.schema.encodeRequestWorkspaceSnapshot(buffer, value),
        .create_tab => |*value| encode: {
            var argument_scratch: [OwnedCreateTab.max_owned_arguments][]const u8 = undefined;
            break :encode source_namespace.schema.encodeCreateTab(
                buffer,
                value.view(outbox.launchCwd(outbox.head), &argument_scratch),
            );
        },
        .rename_tab => |*value| source_namespace.schema.encodeRenameTab(buffer, .{
            .request_id = value.request_id,
            .location = value.location,
            .label = value.slice(),
        }),
        .close_tab => |value| source_namespace.schema.encodeCloseTab(buffer, value),
        .move_tab => |value| source_namespace.schema.encodeMoveTab(buffer, value),
        .request_graphics_snapshot => |value| source_namespace.schema.encodeRequestGraphicsSnapshot(buffer, value),
        .graphics_credit => |value| source_namespace.schema.encodeGraphicsCredit(buffer, value),
        .configure_graphics => |value| source_namespace.schema.encodeConfigureGraphics(buffer, value),
        .configure_terminal_colors => |value| source_namespace.schema.encodeConfigureTerminalColors(buffer, value),
        .request_runtime_state => |value| source_namespace.schema.encodeRequestRuntimeState(buffer, value),
        .create_workspace => |*value| source_namespace.schema.encodeCreateWorkspace(
            buffer,
            value.view(outbox.launchCwd(outbox.head)),
        ),
        .rename_workspace => |*value| source_namespace.schema.encodeRenameWorkspace(buffer, .{
            .request_id = value.request_id,
            .workspace = value.workspace,
            .name = value.slice(),
        }),
        .set_pane_viewport => |value| source_namespace.schema.encodeSetPaneViewport(buffer, value),
        .copy_selection => |value| source_namespace.schema.encodeCopySelection(buffer, value),
        .show_notification => |*value| source_namespace.schema.encodeShowNotification(buffer, value.view()),
        .client_layout => |slot| outbox.client_layouts[slot].slice(),
        .acknowledge_agent => |value| source_namespace.schema.encodeAcknowledgeAgent(buffer, value),
        .search_pane => |*value| source_namespace.schema.encodeSearchPane(buffer, value.view()),
        .query_history => |*value| source_namespace.schema.encodeQueryHistory(buffer, value.view()),
        .delete_history => |value| source_namespace.schema.encodeDeleteHistory(buffer, value),
        .read_history_output => |value| source_namespace.schema.encodeReadHistoryOutput(buffer, value),
        .suggest_command => |*value| source_namespace.schema.encodeSuggestCommand(buffer, value.view()),
        .complete_pane_focus => |value| source_namespace.schema.encodeCompletePaneFocus(buffer, value),
    };
}

fn append(outbox: *Outbox, message: source_namespace.Message) !void {
    const launch_slot = if (source_namespace.messageLaunchCwd(message)) |cwd|
        try outbox.claimLaunchCwd(cwd)
    else
        null;
    errdefer if (launch_slot) |slot| outbox.releaseLaunchSlot(slot);
    const index = try outbox.reserve();
    outbox.item_launch_cwd[index] = launch_slot;
    outbox.items[index] = message;
}

fn claimLaunchCwd(outbox: *Outbox, cwd: []const u8) !u8 {
    if (cwd.len == 0 or cwd.len > source_namespace.schema.max_cwd_bytes) {
        return error.InvalidCwd;
    }
    for (&outbox.launch_cwds, 0..) |*slot, index| {
        if (slot.used) {
            continue;
        }
        @memcpy(slot.bytes[0..cwd.len], cwd);
        slot.len = @intCast(cwd.len);
        slot.used = true;
        return @intCast(index);
    }
    return error.TooManyPendingLaunches;
}

fn launchCwd(outbox: *const Outbox, item_index: usize) []const u8 {
    const slot = outbox.item_launch_cwd[item_index] orelse unreachable;
    return outbox.launch_cwds[slot].slice();
}

fn releaseLaunchCwd(outbox: *Outbox, item_index: usize) void {
    const slot = outbox.item_launch_cwd[item_index] orelse return;
    outbox.releaseLaunchSlot(slot);
    outbox.item_launch_cwd[item_index] = null;
}

fn releaseLaunchSlot(outbox: *Outbox, slot_index: u8) void {
    const slot = &outbox.launch_cwds[slot_index];
    std.debug.assert(slot.used);
    slot.len = 0;
    slot.used = false;
}

fn claimClientLayout(outbox: *Outbox, update: source_namespace.schema.ClientLayoutUpdate) !u8 {
    for (&outbox.client_layouts, 0..) |*slot, index| {
        if (slot.used) {
            continue;
        }

        const encoded = try source_namespace.schema.encodeClientLayoutUpdate(&slot.bytes, update);
        slot.len = @intCast(encoded.len);
        slot.used = true;
        return @intCast(index);
    }

    return error.TooManyPendingClientLayouts;
}

fn releaseClientLayout(outbox: *Outbox, item_index: usize) void {
    const slot = switch (outbox.items[item_index]) {
        .client_layout => |slot_index| slot_index,
        else => return,
    };

    outbox.releaseClientLayoutSlot(slot);
}

fn releaseClientLayoutSlot(outbox: *Outbox, slot_index: u8) void {
    const slot = &outbox.client_layouts[slot_index];
    std.debug.assert(slot.used);
    slot.len = 0;
    slot.used = false;
}

fn reserve(outbox: *Outbox) !usize {
    if (outbox.len == source_namespace.capacity) {
        outbox.stats.saturated +|= 1;
        return error.ClientOutboxFull;
    }
    const index = (@as(usize, outbox.head) + outbox.len) % source_namespace.capacity;
    outbox.len += 1;
    outbox.stats.high_water = @max(outbox.stats.high_water, outbox.len);
    return index;
}

fn tailIndex(outbox: *const Outbox) ?usize {
    if (outbox.len == 0) {
        return null;
    }
    return (@as(usize, outbox.head) + outbox.len - 1) % source_namespace.capacity;
}

fn mutableTailIndex(outbox: *const Outbox) ?usize {
    const index = outbox.tailIndex() orelse return null;
    if (outbox.send_pending and index == outbox.head) {
        return null;
    }
    return index;
}

fn pushResize(outbox: *Outbox, resize: source_namespace.schema.PaneResize) !void {
    var offset: usize = 0;
    const mutable_len = outbox.len - @intFromBool(outbox.send_pending);
    while (offset < mutable_len) : (offset += 1) {
        const index = (@as(usize, outbox.head) + outbox.len - 1 - offset) % source_namespace.capacity;
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

fn pushAck(outbox: *Outbox, ack: source_namespace.schema.FrameAck) !void {
    var offset: usize = 0;
    const mutable_len = outbox.len - @intFromBool(outbox.send_pending);
    while (offset < mutable_len) : (offset += 1) {
        const index = (@as(usize, outbox.head) + outbox.len - 1 - offset) % source_namespace.capacity;
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
