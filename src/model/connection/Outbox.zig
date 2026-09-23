const RuntimeBootstrap = @import("RuntimeBootstrap.zig");
const data = @import("../model.zig");
const outbox_support = @import("outbox_support.zig");
const OwnedLaunchCwd = @import("OwnedLaunchCwd.zig");
const OwnedClientLayout = @import("OwnedClientLayout.zig");
const Stats = @import("Stats.zig");
const Snapshot = @import("OutboxSnapshot.zig");
const OwnedRename = @import("OwnedRename.zig");
const OwnedWorkspaceRename = @import("OwnedWorkspaceRename.zig");
const OwnedCreateWorkspace = @import("OwnedCreateWorkspace.zig");
const OwnedCreateTab = @import("OwnedCreateTab.zig");
const OwnedNotification = @import("OwnedNotification.zig");
const std = @import("std");
const core = @import("telar-core");
const Outbox = @This();

const Payloads = [outbox_support.capacity][data.input_limits.max_encoded_bytes]u8;

items: [outbox_support.capacity]outbox_support.Message = undefined,
/// Owned payload bytes, one slot per queued message. Reserved once on the
/// heap so the model stays small enough to live on a test stack.
input_bytes: ?*Payloads = null,
launch_cwds: [outbox_support.max_pending_launches]OwnedLaunchCwd =
    [_]OwnedLaunchCwd{.{}} ** outbox_support.max_pending_launches,
client_layouts: [2]OwnedClientLayout = [_]OwnedClientLayout{.{}} ** 2,
item_launch_cwd: [outbox_support.capacity]?u8 = @splat(null),
head: u8 = 0,
len: u8 = 0,
send_pending: bool = false,
stats: Stats = .{},

/// Reserves payload storage before the first message is queued. The
/// interactive path then never allocates.
/// Example: `try model.to_runtime.reservePayloads(gpa);`
pub fn reservePayloads(outbox: *Outbox, gpa: std.mem.Allocator) !void {
    if (outbox.input_bytes == null) {
        outbox.input_bytes = try gpa.create(Payloads);
    }
}

pub fn deinit(outbox: *Outbox, gpa: std.mem.Allocator) void {
    if (outbox.input_bytes) |payloads| {
        gpa.destroy(payloads);
    }

    outbox.input_bytes = null;
}

/// Example: `const init: Outbox = try .init(gpa);`
pub fn init(gpa: std.mem.Allocator) !Outbox {
    var outbox: Outbox = .{};
    try outbox.reservePayloads(gpa);
    return outbox;
}

fn payloadAt(outbox: anytype, index: usize) *[data.input_limits.max_encoded_bytes]u8 {
    return &outbox.input_bytes.?[index];
}

pub fn hasCapacity(outbox: *const Outbox) bool {
    return outbox.len < outbox_support.capacity;
}

/// Reports how many complete messages the bounded queue can still own.
///
/// ```zig
/// const available = outbox.availableCapacity();
/// ```
pub fn availableCapacity(outbox: *const Outbox) usize {
    return outbox_support.capacity - @as(usize, outbox.len);
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

/// Retains a completion outside the small per-message metadata. Example: `try outbox.pushClientCompletion(reply);`
/// Queues the ordered bootstrap after host negotiation. Capacity is checked
/// before any frame is queued.
///
/// ```zig
/// try model.to_runtime.pushBootstrap(.{ .graphics_shared = true, .client_identity = identity });
/// ```
pub fn pushBootstrap(outbox: *Outbox, request: RuntimeBootstrap) !void {
    if (outbox.availableCapacity() < 3) {
        return error.ClientOutboxFull;
    }

    try outbox.push(.{ .configure_graphics = .{ .shared = request.graphics_shared } });
    try outbox.push(.{ .configure_terminal_colors = request.terminal_colors });
    try outbox.push(.{ .request_runtime_state = .{ .client_identity = request.client_identity } });
}

pub fn pushClientCompletion(self: *Outbox, reply: core.ClientCommand) !void {
    try reply.validateWire();
    const index = try self.reserve();
    const encoded = core.encodeCompleteClientCommand(self.payloadAt(index), reply) catch unreachable;
    self.item_launch_cwd[index] = null;
    self.items[index] = .{ .complete_client_command = @intCast(encoded.len) };
}

pub fn push(outbox: *Outbox, message: outbox_support.Message) !void {
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
        .pane_input, .agent_prompt, .query_agent_history, .create_tab, .create_workspace, .rename_tab, .rename_workspace, .show_notification, .client_layout, .query_change_review, .change_review_command, .complete_client_command => unreachable,
        else => {},
    }
    try outbox.append(message);
}

pub fn pushInput(outbox: *Outbox, pane_id: core.PaneId, bytes: []const u8) !void {
    if (bytes.len == 0 or bytes.len > data.input_limits.max_encoded_bytes) {
        return error.InvalidInputLength;
    }
    if (outbox.mutableTailIndex()) |index| {
        switch (outbox.items[index]) {
            .pane_input => |*input| {
                if (input.pane_id == pane_id and
                    bytes.len <= outbox.payloadAt(index).len - input.len)
                {
                    @memcpy(outbox.payloadAt(index)[input.len..][0..bytes.len], bytes);
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
    @memcpy(outbox.payloadAt(index)[0..bytes.len], bytes);
}

/// Owns one prompt in the existing slot byte storage without coalescing turns.
/// Example: `try outbox.pushAgentPrompt(prompt);`
pub fn pushAgentPrompt(outbox: *Outbox, prompt: core.AgentPrompt) !void {
    try prompt.images.validate();
    if ((prompt.text.len == 0 and prompt.images.count == 0) or prompt.text.len > core.agent_thread.max_prompt_bytes or prompt.text.len > data.input_limits.max_encoded_bytes or !std.unicode.utf8ValidateSlice(prompt.text) or std.mem.indexOfScalar(u8, prompt.text, 0) != null) {
        return error.InvalidAgentPrompt;
    }
    if (!prompt.options.valid()) {
        return error.InvalidAgentOptions;
    }

    var total = prompt.text.len;
    for (prompt.images.storage[0..prompt.images.count]) |path| {
        total += path.len;
    }

    if (total > data.input_limits.max_encoded_bytes) {
        return error.InvalidAgentPrompt;
    }

    const index = try outbox.reserve();
    outbox.item_launch_cwd[index] = null;
    outbox.items[index] = .{ .agent_prompt = .{
        .request_id = prompt.request_id,
        .pane_id = prompt.pane_id,
        .pane_generation = prompt.pane_generation,
        .len = @intCast(prompt.text.len),
        .options = prompt.options,
        .image_count = prompt.images.count,
    } };
    @memcpy(outbox.payloadAt(index)[0..prompt.text.len], prompt.text);
    var offset = prompt.text.len;
    for (prompt.images.storage[0..prompt.images.count], 0..) |path, image_index| {
        outbox.items[index].agent_prompt.image_lengths[image_index] = @intCast(path.len);
        @memcpy(outbox.payloadAt(index)[offset..][0..path.len], path);
        offset += path.len;
    }
}

/// Owns cursors in the existing outbound byte slot without per-input allocation.
/// Example: `try outbox.pushAgentHistory(query);`
pub fn pushAgentHistory(outbox: *Outbox, query: core.QueryAgentHistory) !void {
    _ = try core.AgentHistoryCursor.init(query.cursor);
    _ = try core.AgentHistoryCursor.init(query.anchor);
    _ = try core.AgentHistoryCursor.init(query.anchor_turn);
    if (query.cursor.len + query.anchor.len + query.anchor_turn.len > data.input_limits.max_encoded_bytes) {
        return error.InvalidAgentHistoryCursor;
    }
    const index = try outbox.reserve();
    outbox.item_launch_cwd[index] = null;
    outbox.items[index] = .{ .query_agent_history = .{ .request_id = query.request_id, .pane_id = query.pane_id, .pane_generation = query.pane_generation, .view_generation = query.view_generation, .cursor_len = @intCast(query.cursor.len), .anchor_len = @intCast(query.anchor.len), .anchor_turn_len = @intCast(query.anchor_turn.len), .direction = query.direction } };
    @memcpy(outbox.payloadAt(index)[0..query.cursor.len], query.cursor);
    @memcpy(outbox.payloadAt(index)[query.cursor.len..][0..query.anchor.len], query.anchor);
    @memcpy(outbox.payloadAt(index)[query.cursor.len + query.anchor.len ..][0..query.anchor_turn.len], query.anchor_turn);
}

/// Owns the complete encoded command in an existing byte slot before input returns.
/// Example: `try outbox.pushChangeReviewCommand(command);`
pub fn pushChangeReviewCommand(self: *Outbox, command: core.ChangeReviewCommand) !void {
    try self.pushReview(command);
}

/// Owns the provider conversation identity before a review changes or closes.
/// Example: `try outbox.pushChangeReviewQuery(query);`
pub fn pushChangeReviewQuery(self: *Outbox, query: core.QueryChangeReview) !void {
    try self.pushReview(query);
}

fn pushReview(self: *Outbox, value: anytype) !void {
    const query = @TypeOf(value) == core.QueryChangeReview;
    var scratch: [data.input_limits.max_encoded_bytes]u8 = undefined;
    const encoded = if (query) try core.encodeQueryChangeReview(&scratch, value) else try core.encodeChangeReviewCommand(&scratch, value);
    const index = try self.reserve();
    self.item_launch_cwd[index] = null;
    self.items[index] = if (query) .{ .query_change_review = @intCast(encoded.len) } else .{ .change_review_command = @intCast(encoded.len) };
    @memcpy(self.payloadAt(index)[0..encoded.len], encoded);
}

/// Reserves a whole bounded paste before copying any chunk into the queue.
/// Example: `try outbox.pushInputBatch(pane_id, encoded_paste);`.
pub fn pushInputBatch(outbox: *Outbox, pane_id: core.PaneId, bytes: []const u8) !void {
    if (bytes.len == 0 or bytes.len > core.max_history_command_bytes + 13) {
        return error.InvalidInputLength;
    }

    const count = (bytes.len + data.input_limits.max_encoded_bytes - 1) / data.input_limits.max_encoded_bytes;
    if (outbox.availableCapacity() < count) {
        return error.ClientOutboxFull;
    }

    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + data.input_limits.max_encoded_bytes, bytes.len);
        try outbox.pushInput(pane_id, bytes[offset..end]);
        offset = end;
    }
}

pub fn pushRename(outbox: *Outbox, rename: core.RenameTab) !void {
    if (rename.label.len == 0 or rename.label.len > core.max_tab_label_bytes) {
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

pub fn pushWorkspaceRename(outbox: *Outbox, rename: core.RenameWorkspace) !void {
    if (rename.name.len == 0 or rename.name.len > core.max_tab_label_bytes) {
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

pub fn pushCreateWorkspace(outbox: *Outbox, request: core.CreateWorkspace) !void {
    if (request.name.len == 0 or request.name.len > core.max_tab_label_bytes) {
        return error.InvalidWorkspaceName;
    }

    var owned: OwnedCreateWorkspace = .{
        .request_id = request.request_id,
        .size = request.size,
        .name_len = @intCast(request.name.len),
        .launch = request.launch,
        .create_cwd = request.create_cwd,
    };
    @memcpy(owned.name[0..request.name.len], request.name);
    try outbox.append(.{ .create_workspace = owned });
}

pub fn pushCreateTab(outbox: *Outbox, request: core.CreateTab) !void {
    if (request.label.len > core.max_tab_label_bytes) {
        return error.InvalidTabLabel;
    }

    var owned: OwnedCreateTab = .{
        .kind = request.kind,
        .request_id = request.request_id,
        .workspace = request.workspace,
        .label_len = @intCast(request.label.len),
        .size = request.size,
        .launch = request.launch,
    };
    @memcpy(owned.label[0..request.label.len], request.label);
    try outbox.append(.{ .create_tab = owned });
}

pub fn pushNotification(outbox: *Outbox, request: core.ShowNotification) !void {
    if (request.notification.title.len > core.max_notification_title_bytes or
        request.notification.message.len > core.max_notification_message_bytes)
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
pub fn pushClientLayout(outbox: *Outbox, update: core.ClientLayoutUpdate) !void {
    var offset: usize = 0;
    const mutable_len = outbox.len - @intFromBool(outbox.send_pending);
    while (offset < mutable_len) : (offset += 1) {
        const index = (@as(usize, outbox.head) + outbox.len - 1 - offset) % outbox_support.capacity;
        switch (outbox.items[index]) {
            .client_layout => |slot_index| {
                const slot = &outbox.client_layouts[slot_index];
                var scratch: [core.max_client_layout_wire_bytes]u8 = undefined;
                const encoded = try core.encodeClientLayoutUpdate(&scratch, update);
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

pub fn peek(outbox: *const Outbox) ?*const outbox_support.Message {
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
    outbox.head = @intCast((@as(usize, outbox.head) + 1) % outbox_support.capacity);
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
            return core.encodeOpenPane(buffer, owned);
        },
        .pane_input => |value| core.encodePaneInput(buffer, .{
            .pane_id = value.pane_id,
            .bytes = outbox.payloadAt(outbox.head)[0..value.len],
        }),
        .pane_resize => |value| core.encodePaneResize(buffer, value),
        .frame_ack => |value| core.encodeFrameAck(buffer, value),
        .request_snapshot => |value| core.encodeRequestSnapshot(buffer, value),
        .detach_pane => |value| core.encodeDetachPane(buffer, value),
        .request_tab_snapshot => |value| core.encodeRequestTabSnapshot(buffer, value),
        .create_pane => |value| {
            var scratch: [core.max_argument_count][]const u8 = undefined;
            var owned = value.view(outbox.payloadAt(outbox.head), &scratch);
            owned.launch.cwd = outbox.launchCwd(outbox.head);
            return core.encodeCreatePane(buffer, owned);
        },
        .close_pane => |value| core.encodeClosePane(buffer, value),
        .request_workspace_snapshot => |value| core.encodeRequestWorkspaceSnapshot(buffer, value),
        .create_tab => |*value| encode: {
            var scratch: [core.max_argument_count][]const u8 = undefined;
            var owned = value.view(outbox.payloadAt(outbox.head), &scratch);
            owned.launch.cwd = outbox.launchCwd(outbox.head);
            break :encode core.encodeCreateTab(buffer, owned);
        },
        .rename_tab => |*value| core.encodeRenameTab(buffer, .{
            .request_id = value.request_id,
            .location = value.location,
            .label = value.slice(),
        }),
        .close_tab => |value| core.encodeCloseTab(buffer, value),
        .move_tab => |value| core.encodeMoveTab(buffer, value),
        .request_graphics_snapshot => |value| core.encodeRequestGraphicsSnapshot(buffer, value),
        .graphics_credit => |value| core.encodeGraphicsCredit(buffer, value),
        .configure_graphics => |value| core.encodeConfigureGraphics(buffer, value),
        .configure_terminal_colors => |value| core.encodeConfigureTerminalColors(buffer, value),
        .request_runtime_state => |value| core.encodeRequestRuntimeState(buffer, value),
        .create_workspace => |*value| core.encodeCreateWorkspace(
            buffer,
            value.view(outbox.launchCwd(outbox.head)),
        ),
        .rename_workspace => |*value| core.encodeRenameWorkspace(buffer, .{
            .request_id = value.request_id,
            .workspace = value.workspace,
            .name = value.slice(),
        }),
        .set_pane_viewport => |value| core.encodeSetPaneViewport(buffer, value),
        .copy_selection => |value| core.encodeCopySelection(buffer, value),
        .show_notification => |*value| core.encodeShowNotification(buffer, value.view()),
        .client_layout => |slot| outbox.client_layouts[slot].slice(),
        .acknowledge_agent => |value| core.encodeAcknowledgeAgent(buffer, value),
        .search_pane => |*value| core.encodeSearchPane(buffer, value.view()),
        .query_history => |*value| core.encodeQueryHistory(buffer, value.view()),
        .delete_history => |value| core.encodeDeleteHistory(buffer, value),
        .read_history_output => |value| core.encodeReadHistoryOutput(buffer, value),
        .suggest_command => |*value| core.encodeSuggestCommand(buffer, value.view()),
        .complete_client_command => |length| outbox.payloadAt(outbox.head)[0..length],
        .open_editor => |value| encode: {
            var request = value;
            const bytes = outbox.payloadAt(outbox.head);
            request.editor = bytes[0..value.editor.len];
            request.path = bytes[value.editor.len..][0..value.path.len];
            break :encode core.encodeOpenEditor(buffer, request);
        },
        .complete_pane_focus => |value| core.encodeCompletePaneFocus(buffer, value),
        .agent_prompt => |*value| core.encodeAgentPrompt(buffer, value.view(outbox.payloadAt(outbox.head))),
        .agent_interrupt => |value| core.encodeAgentInterrupt(buffer, value),
        .agent_resume => |value| core.encodeAgentResume(buffer, value),
        .agent_approval => |value| core.encodeAgentApproval(buffer, value),
        .query_change_review, .change_review_command => |len| outbox.payloadAt(outbox.head)[0..len],
        .query_agent_thread => |value| core.encodeQueryAgentThread(buffer, value),
        .query_agent_history => |*value| core.encodeQueryAgentHistory(buffer, value.view(outbox.payloadAt(outbox.head))),
    };
}

fn append(outbox: *Outbox, message: outbox_support.Message) !void {
    const launch_slot = if (outbox_support.messageLaunchCwd(message)) |cwd|
        try outbox.claimLaunchCwd(cwd)
    else
        null;
    errdefer if (launch_slot) |slot| outbox.releaseLaunchSlot(slot);
    const index = try outbox.reserve();
    errdefer outbox.len -= 1;
    var owned = message;
    if (owned == .open_editor) {
        try owned.open_editor.validateWire();
        const request = owned.open_editor;
        if (request.editor.len + request.path.len > data.input_limits.max_encoded_bytes) {
            return error.InvalidEditorTarget;
        }

        @memcpy(outbox.payloadAt(index)[0..request.editor.len], request.editor);
        @memcpy(outbox.payloadAt(index)[request.editor.len..][0..request.path.len], request.path);
        owned.open_editor.editor = outbox.payloadAt(index)[0..request.editor.len];
        owned.open_editor.path = outbox.payloadAt(index)[request.editor.len..][0..request.path.len];
    } else if (owned == .create_pane) {
        try owned.create_pane.ownArguments(outbox.payloadAt(index));
    } else if (owned == .create_tab) {
        try owned.create_tab.ownArguments(outbox.payloadAt(index));
    }

    outbox.item_launch_cwd[index] = launch_slot;
    outbox.items[index] = owned;
}

fn claimLaunchCwd(outbox: *Outbox, cwd: []const u8) !u8 {
    if (cwd.len == 0 or cwd.len > core.max_cwd_bytes) {
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

fn claimClientLayout(outbox: *Outbox, update: core.ClientLayoutUpdate) !u8 {
    for (&outbox.client_layouts, 0..) |*slot, index| {
        if (slot.used) {
            continue;
        }

        const encoded = try core.encodeClientLayoutUpdate(&slot.bytes, update);
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
    if (outbox.len == outbox_support.capacity) {
        outbox.stats.saturated +|= 1;
        return error.ClientOutboxFull;
    }
    const index = (@as(usize, outbox.head) + outbox.len) % outbox_support.capacity;
    outbox.len += 1;
    outbox.stats.high_water = @max(outbox.stats.high_water, outbox.len);
    return index;
}

fn tailIndex(outbox: *const Outbox) ?usize {
    if (outbox.len == 0) {
        return null;
    }
    return (@as(usize, outbox.head) + outbox.len - 1) % outbox_support.capacity;
}

fn mutableTailIndex(outbox: *const Outbox) ?usize {
    const index = outbox.tailIndex() orelse return null;
    if (outbox.send_pending and index == outbox.head) {
        return null;
    }
    return index;
}

fn pushResize(outbox: *Outbox, resize: core.PaneResize) !void {
    var offset: usize = 0;
    const mutable_len = outbox.len - @intFromBool(outbox.send_pending);
    while (offset < mutable_len) : (offset += 1) {
        const index = (@as(usize, outbox.head) + outbox.len - 1 - offset) % outbox_support.capacity;
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

fn pushAck(outbox: *Outbox, ack: core.FrameAck) !void {
    var offset: usize = 0;
    const mutable_len = outbox.len - @intFromBool(outbox.send_pending);
    while (offset < mutable_len) : (offset += 1) {
        const index = (@as(usize, outbox.head) + outbox.len - 1 - offset) % outbox_support.capacity;
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

test "runtime bootstrap queues colors before subscribing to the initial layout" {
    var outbox: Outbox = try .init(std.testing.allocator);
    defer outbox.deinit(std.testing.allocator);
    var buffer: [core.max_frame_size]u8 = undefined;

    try outbox.pushBootstrap(.{
        .graphics_shared = true,
        .client_identity = @enumFromInt(9),
    });

    const configure = try core.decodeClient((try outbox.beginSend(&buffer)).?);
    try std.testing.expect(configure == .configure_graphics);
    try std.testing.expect(configure.configure_graphics.shared);

    try outbox.finishSend({});
    const colors = try core.decodeClient((try outbox.beginSend(&buffer)).?);
    try std.testing.expect(colors == .configure_terminal_colors);
    try outbox.finishSend({});

    const runtime_state = try core.decodeClient((try outbox.beginSend(&buffer)).?);
    try std.testing.expect(runtime_state == .request_runtime_state);
    try std.testing.expectEqual(@as(core.ClientIdentity, @enumFromInt(9)), runtime_state.request_runtime_state.client_identity);
}
