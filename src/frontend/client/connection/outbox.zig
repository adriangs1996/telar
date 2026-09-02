//! Bounded, allocation-free queue for messages sent by one frontend client.
//!
//! Variable input, creation labels, rename, notification, and launch-cwd bytes are copied
//! because their producers may reuse or replace their buffers as soon as the
//! event handler returns. One encoded buffer is borrowed only while a send
//! actor is active.

const std = @import("std");
const core = @import("telar-core");
const pane_input = @import("../application/input/pane_input.zig");

const schema = core.schema;

pub const capacity = schema.max_panes_per_tab + 16;
pub const max_input_bytes = pane_input.max_bytes;
/// Request groups permit at most one pane launch, one tab launch, and one
/// workspace launch at once. Keep one spare for bootstrap or recovery.
pub const max_pending_launches = 4;

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

const OwnedCreateWorkspace = struct {
    request_id: schema.RequestId,
    size: schema.TerminalSize,
    name: [schema.max_tab_label_bytes]u8 = undefined,
    name_len: u8,
    launch: schema.Launch,

    fn view(value: *const OwnedCreateWorkspace, cwd: []const u8) schema.CreateWorkspace {
        var launch = value.launch;
        launch.cwd = cwd;

        return .{
            .request_id = value.request_id,
            .size = value.size,
            .name = value.name[0..value.name_len],
            .launch = launch,
        };
    }
};

const OwnedCreateTab = struct {
    const max_owned_arguments = 8;
    const max_owned_argument_bytes = 224;

    request_id: schema.RequestId,
    workspace: schema.WorkspaceLocation,
    label: [schema.max_tab_label_bytes]u8 = undefined,
    label_len: u8,
    size: schema.TerminalSize,
    launch: schema.Launch,
    /// NUL-free bytes of a bounded owned argv; zero count borrows
    /// `launch.arguments`, which is only safe for process-lifetime slices.
    argument_storage: [max_owned_argument_bytes]u8 = undefined,
    argument_lens: [max_owned_arguments]u8 = undefined,
    argument_count: u8 = 0,

    fn ownArguments(value: *OwnedCreateTab, arguments: []const []const u8) bool {
        if (arguments.len == 0 or arguments.len > max_owned_arguments) return false;
        var total: usize = 0;
        for (arguments) |argument| total += argument.len;
        if (total > max_owned_argument_bytes) return false;

        var offset: usize = 0;
        for (arguments, 0..) |argument, index| {
            @memcpy(value.argument_storage[offset .. offset + argument.len], argument);
            value.argument_lens[index] = @intCast(argument.len);
            offset += argument.len;
        }
        value.argument_count = @intCast(arguments.len);
        return true;
    }

    fn view(value: *const OwnedCreateTab, cwd: []const u8, scratch: *[max_owned_arguments][]const u8) schema.CreateTab {
        var launch = value.launch;
        launch.cwd = cwd;
        if (value.argument_count != 0) {
            var offset: usize = 0;
            for (0..value.argument_count) |index| {
                const len = value.argument_lens[index];
                scratch[index] = value.argument_storage[offset .. offset + len];
                offset += len;
            }
            launch.arguments = scratch[0..value.argument_count];
        }

        return .{
            .request_id = value.request_id,
            .workspace = value.workspace,
            .label = value.label[0..value.label_len],
            .size = value.size,
            .launch = launch,
        };
    }
};

pub const OwnedHistoryQuery = struct {
    /// The palette query comes from the prompt field, which is bounded by
    /// the tab-label capacity; the caps keep queue messages small.
    pub const max_query_bytes = 128;
    pub const max_scope_bytes = 256;

    request_id: schema.RequestId,
    query: [max_query_bytes]u8 = undefined,
    query_len: u8 = 0,
    scope: schema.HistoryScope = .global,
    scope_value: [max_scope_bytes]u8 = undefined,
    scope_value_len: u16 = 0,
    pane_id: schema.PaneId = .invalid,
    author: schema.HistoryAuthorFilter = .all,
    limit: u16,

    fn view(value: *const OwnedHistoryQuery) schema.QueryHistory {
        return .{
            .request_id = value.request_id,
            .query = value.query[0..value.query_len],
            .scope = value.scope,
            .scope_value = value.scope_value[0..value.scope_value_len],
            .pane_id = value.pane_id,
            .failed_only = false,
            .author = value.author,
            .limit = value.limit,
        };
    }
};

pub const OwnedSearch = struct {
    request_id: schema.RequestId,
    pane_id: schema.PaneId,
    needle: [schema.max_search_needle_bytes]u8 = undefined,
    needle_len: u8 = 0,

    fn view(value: *const OwnedSearch) schema.SearchPane {
        return .{
            .request_id = value.request_id,
            .pane_id = value.pane_id,
            .needle = value.needle[0..value.needle_len],
        };
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

const OwnedLaunchCwd = struct {
    bytes: [schema.max_cwd_bytes]u8 = undefined,
    len: u16 = 0,
    used: bool = false,

    fn slice(cwd: *const OwnedLaunchCwd) []const u8 {
        std.debug.assert(cwd.used and cwd.len != 0);
        return cwd.bytes[0..cwd.len];
    }
};

const OwnedClientLayout = struct {
    bytes: [schema.max_client_layout_wire_bytes]u8 = undefined,
    len: u16 = 0,
    used: bool = false,

    fn slice(layout: *const OwnedClientLayout) []const u8 {
        std.debug.assert(layout.used and layout.len != 0);
        return layout.bytes[0..layout.len];
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
    create_tab: OwnedCreateTab,
    rename_tab: OwnedRename,
    close_tab: schema.CloseTab,
    move_tab: schema.MoveTab,
    request_graphics_snapshot: schema.RequestGraphicsSnapshot,
    graphics_credit: schema.GraphicsCredit,
    configure_graphics: schema.ConfigureGraphics,
    create_workspace: OwnedCreateWorkspace,
    rename_workspace: OwnedWorkspaceRename,
    set_pane_viewport: schema.SetPaneViewport,
    copy_selection: schema.CopySelection,
    show_notification: OwnedNotification,
    client_layout: u8,
    acknowledge_agent: schema.AcknowledgeAgent,
    search_pane: OwnedSearch,
    query_history: OwnedHistoryQuery,
    delete_history: schema.DeleteHistory,
};

fn messageLaunchCwd(message: Message) ?[]const u8 {
    return switch (message) {
        .open_pane => |value| if (value.launch) |launch| launch.cwd else null,
        .create_pane => |value| value.launch.cwd,
        .create_tab => |value| value.launch.cwd,
        .create_workspace => |value| value.launch.cwd,
        else => null,
    };
}

pub const Stats = struct {
    high_water: u8 = 0,
    saturated: u64 = 0,
    coalesced_input: u64 = 0,
    coalesced_resize: u64 = 0,
    coalesced_ack: u64 = 0,
    coalesced_client_layout: u64 = 0,
};

pub const Snapshot = struct {
    depth: u8 = 0,
    high_water: u8 = 0,
    saturated: u64 = 0,
    coalesced_input: u64 = 0,
    coalesced_resize: u64 = 0,
    coalesced_ack: u64 = 0,
    coalesced_client_layout: u64 = 0,
};

pub const Outbox = struct {
    items: [capacity]Message = undefined,
    input_bytes: [capacity][max_input_bytes]u8 = undefined,
    launch_cwds: [max_pending_launches]OwnedLaunchCwd =
        [_]OwnedLaunchCwd{.{}} ** max_pending_launches,
    client_layouts: [2]OwnedClientLayout = [_]OwnedClientLayout{.{}} ** 2,
    item_launch_cwd: [capacity]?u8 = @splat(null),
    head: u8 = 0,
    len: u8 = 0,
    send_pending: bool = false,
    stats: Stats = .{},

    pub fn hasCapacity(outbox: *const Outbox) bool {
        return outbox.len < capacity;
    }

    /// Reports how many complete messages the bounded queue can still own.
    ///
    /// ```zig
    /// const available = outbox.availableCapacity();
    /// ```
    pub fn availableCapacity(outbox: *const Outbox) usize {
        return capacity - @as(usize, outbox.len);
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

    pub fn push(outbox: *Outbox, message: Message) !void {
        switch (message) {
            .pane_resize => |resize| return outbox.pushResize(resize),
            .frame_ack => |ack| return outbox.pushAck(ack),
            .pane_input, .create_tab, .create_workspace, .rename_tab, .rename_workspace, .show_notification, .client_layout => unreachable,
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
        outbox.item_launch_cwd[index] = null;
        outbox.items[index] = .{ .pane_input = .{
            .pane_id = pane_id,
            .len = @intCast(bytes.len),
        } };
        @memcpy(outbox.input_bytes[index][0..bytes.len], bytes);
    }

    pub fn pushRename(outbox: *Outbox, rename: schema.RenameTab) !void {
        if (rename.label.len == 0 or rename.label.len > schema.max_tab_label_bytes) {
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

    pub fn pushCreateWorkspace(outbox: *Outbox, request: schema.CreateWorkspace) !void {
        if (request.name.len == 0 or request.name.len > schema.max_tab_label_bytes) {
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

    pub fn pushCreateTab(outbox: *Outbox, request: schema.CreateTab) !void {
        if (request.label.len > schema.max_tab_label_bytes) {
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

    /// Encodes and coalesces the latest complete client layout without
    /// retaining slices into the mutable model.
    ///
    /// ```zig
    /// try outbox.pushClientLayout(update);
    /// ```
    pub fn pushClientLayout(outbox: *Outbox, update: schema.ClientLayoutUpdate) !void {
        var offset: usize = 0;
        const mutable_len = outbox.len - @intFromBool(outbox.send_pending);
        while (offset < mutable_len) : (offset += 1) {
            const index = (@as(usize, outbox.head) + outbox.len - 1 - offset) % capacity;
            switch (outbox.items[index]) {
                .client_layout => |slot_index| {
                    const slot = &outbox.client_layouts[slot_index];
                    var scratch: [schema.max_client_layout_wire_bytes]u8 = undefined;
                    const encoded = try schema.encodeClientLayoutUpdate(&scratch, update);
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

    pub fn peek(outbox: *const Outbox) ?*const Message {
        if (outbox.len == 0) return null;
        return &outbox.items[outbox.head];
    }

    /// Claims the next queued message: encodes it into `buffer` and marks
    /// the send in flight. Null while a send is already in flight or the
    /// queue is empty. The claim ends in exactly one of `popSent` (the
    /// scheduler delivered it) or `sendFailed` (it never left).
    pub fn beginSend(outbox: *Outbox, buffer: []u8) !?[]const u8 {
        if (outbox.send_pending or outbox.len == 0) return null;
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
        outbox.head = @intCast((@as(usize, outbox.head) + 1) % capacity);
        outbox.len -= 1;
    }

    fn encodeNext(outbox: *const Outbox, buffer: []u8) ![]const u8 {
        const message = outbox.peek() orelse return error.OutboxEmpty;
        return switch (message.*) {
            .open_pane => |value| {
                var owned = value;
                if (owned.launch) |*launch| launch.cwd = outbox.launchCwd(outbox.head);
                return schema.encodeOpenPane(buffer, owned);
            },
            .pane_input => |value| schema.encodePaneInput(buffer, .{
                .pane_id = value.pane_id,
                .bytes = outbox.input_bytes[outbox.head][0..value.len],
            }),
            .pane_resize => |value| schema.encodePaneResize(buffer, value),
            .frame_ack => |value| schema.encodeFrameAck(buffer, value),
            .request_snapshot => |value| schema.encodeRequestSnapshot(buffer, value),
            .detach_pane => |value| schema.encodeDetachPane(buffer, value),
            .request_tab_snapshot => |value| schema.encodeRequestTabSnapshot(buffer, value),
            .create_pane => |value| {
                var owned = value;
                owned.launch.cwd = outbox.launchCwd(outbox.head);
                return schema.encodeCreatePane(buffer, owned);
            },
            .close_pane => |value| schema.encodeClosePane(buffer, value),
            .request_workspace_snapshot => |value| schema.encodeRequestWorkspaceSnapshot(buffer, value),
            .create_tab => |*value| encode: {
                var argument_scratch: [OwnedCreateTab.max_owned_arguments][]const u8 = undefined;
                break :encode schema.encodeCreateTab(
                    buffer,
                    value.view(outbox.launchCwd(outbox.head), &argument_scratch),
                );
            },
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
            .create_workspace => |*value| schema.encodeCreateWorkspace(
                buffer,
                value.view(outbox.launchCwd(outbox.head)),
            ),
            .rename_workspace => |*value| schema.encodeRenameWorkspace(buffer, .{
                .request_id = value.request_id,
                .workspace = value.workspace,
                .name = value.slice(),
            }),
            .set_pane_viewport => |value| schema.encodeSetPaneViewport(buffer, value),
            .copy_selection => |value| schema.encodeCopySelection(buffer, value),
            .show_notification => |*value| schema.encodeShowNotification(buffer, value.view()),
            .client_layout => |slot| outbox.client_layouts[slot].slice(),
            .acknowledge_agent => |value| schema.encodeAcknowledgeAgent(buffer, value),
            .search_pane => |*value| schema.encodeSearchPane(buffer, value.view()),
            .query_history => |*value| schema.encodeQueryHistory(buffer, value.view()),
            .delete_history => |value| schema.encodeDeleteHistory(buffer, value),
        };
    }

    fn append(outbox: *Outbox, message: Message) !void {
        const launch_slot = if (messageLaunchCwd(message)) |cwd|
            try outbox.claimLaunchCwd(cwd)
        else
            null;
        errdefer if (launch_slot) |slot| outbox.releaseLaunchSlot(slot);
        const index = try outbox.reserve();
        outbox.item_launch_cwd[index] = launch_slot;
        outbox.items[index] = message;
    }

    fn claimLaunchCwd(outbox: *Outbox, cwd: []const u8) !u8 {
        if (cwd.len == 0 or cwd.len > schema.max_cwd_bytes)
            return error.InvalidCwd;
        for (&outbox.launch_cwds, 0..) |*slot, index| {
            if (slot.used) continue;
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

    fn claimClientLayout(outbox: *Outbox, update: schema.ClientLayoutUpdate) !u8 {
        for (&outbox.client_layouts, 0..) |*slot, index| {
            if (slot.used) {
                continue;
            }

            const encoded = try schema.encodeClientLayoutUpdate(&slot.bytes, update);
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
    const decoded = try schema.decodeClient((try outbox.beginSend(&buffer)).?);
    try std.testing.expectEqualStrings("abcdef", decoded.pane_input.bytes);
}

test "queue metadata stays small when input storage grows" {
    try std.testing.expect(@sizeOf(Message) < 512);
    try std.testing.expect(@sizeOf(Outbox) < 720 * 1024);
}

test "queued launches own cwd bytes until encoding" {
    var outbox: Outbox = .{};
    const pane_id: schema.PaneId = @enumFromInt(1);
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
    const decoded = try schema.decodeClient((try outbox.beginSend(&buffer)).?);
    try std.testing.expectEqualStrings("/work/first", decoded.create_pane.launch.cwd);
    try std.testing.expectEqual(pane_id, decoded.create_pane.launch.cwd_source.?);
}

test "queued tab rename owns bounded label bytes until encoding" {
    var outbox: Outbox = .{};
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(3) },
        .tab_id = @enumFromInt(4),
    };
    const too_long = [_]u8{'x'} ** (schema.max_tab_label_bytes + 1);

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
    const decoded = try schema.decodeClient((try outbox.beginSend(&buffer)).?);
    try std.testing.expectEqualStrings("agents", decoded.rename_tab.label);
    try std.testing.expectEqualDeep(location, decoded.rename_tab.location);
}

test "queued workspace creation owns name and cwd bytes until encoding" {
    var outbox: Outbox = .{};
    const pane_id: schema.PaneId = @enumFromInt(1);
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
    const decoded = try schema.decodeClient((try outbox.beginSend(&buffer)).?);
    try std.testing.expectEqualStrings("agents", decoded.create_workspace.name);
    try std.testing.expectEqualStrings("/work/source", decoded.create_workspace.launch.cwd);
    try std.testing.expectEqual(pane_id, decoded.create_workspace.launch.cwd_source.?);
}

test "queued tab creation owns label and cwd bytes until encoding" {
    var outbox: Outbox = .{};
    const pane_id: schema.PaneId = @enumFromInt(1);
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
    const decoded = try schema.decodeClient((try outbox.beginSend(&buffer)).?);
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

test "input never coalesces into a message already in flight" {
    var outbox: Outbox = .{};
    const pane_id: schema.PaneId = @enumFromInt(1);
    try outbox.pushInput(pane_id, "first");
    var buffer: [64]u8 = undefined;
    var decoded = try schema.decodeClient((try outbox.beginSend(&buffer)).?);
    try std.testing.expectEqualStrings("first", decoded.pane_input.bytes);
    try outbox.pushInput(pane_id, "second");
    try std.testing.expectEqual(@as(u8, 2), outbox.len);

    // A second claim while one is in flight yields nothing.
    try std.testing.expectEqual(@as(?[]const u8, null), try outbox.beginSend(&buffer));
    outbox.popSent();
    decoded = try schema.decodeClient((try outbox.beginSend(&buffer)).?);
    try std.testing.expectEqualStrings("second", decoded.pane_input.bytes);
}

test "client layouts coalesce without mutating an in-flight snapshot" {
    var outbox: Outbox = .{};
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(3) },
        .tab_id = @enumFromInt(4),
    };
    const nodes = [_]schema.ClientLayoutNode{.{ .pane = @enumFromInt(5) }};
    const tabs = [_]schema.ClientTabLayout{.{
        .location = location,
        .focused_pane = @enumFromInt(5),
        .fullscreen = false,
        .workspace_active = true,
        .nodes = &nodes,
    }};
    var update: schema.ClientLayoutUpdate = .{
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

    var buffer: [schema.max_client_layout_wire_bytes]u8 = undefined;
    const first_payload = (try outbox.beginSend(&buffer)).?;
    const first = try schema.decodeClient(first_payload);
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
    const second = try schema.decodeClient((try outbox.beginSend(&buffer)).?);
    try std.testing.expect(second == .update_client_layout);
    try std.testing.expectEqual(@as(u16, 65), second.update_client_layout.sidebar_width);
    outbox.popSent();
    try std.testing.expectEqual(@as(u8, 0), outbox.len);
    try std.testing.expect(!outbox.client_layouts[0].used);
    try std.testing.expect(!outbox.client_layouts[1].used);
}

test "client layout folding never crosses an ordered request" {
    var outbox: Outbox = .{};
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(3) },
        .tab_id = @enumFromInt(4),
    };
    const pane_id: schema.PaneId = @enumFromInt(5);
    const nodes = [_]schema.ClientLayoutNode{.{ .pane = pane_id }};
    const tabs = [_]schema.ClientTabLayout{.{
        .location = location,
        .focused_pane = pane_id,
        .fullscreen = false,
        .workspace_active = true,
        .nodes = &nodes,
    }};
    const update: schema.ClientLayoutUpdate = .{
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
    const pane_id: schema.PaneId = @enumFromInt(1);
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
    const decoded = try schema.decodeClient((try outbox.beginSend(&buffer)).?);
    try std.testing.expectEqual(@as(u16, 2), decoded.create_tab.launch.argument_count);
    var iterator = decoded.create_tab.launch.arguments();
    try std.testing.expectEqualStrings("lazygit", (try iterator.next()).?);
    try std.testing.expectEqualStrings("-p", (try iterator.next()).?);
}
