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
pub fn reservePayloads(self: *Outbox, gpa: std.mem.Allocator) !void {
    if (self.input_bytes == null) {
        self.input_bytes = try gpa.create(Payloads);
    }
}

pub fn deinit(self: *Outbox, gpa: std.mem.Allocator) void {
    if (self.input_bytes) |payloads| {
        gpa.destroy(payloads);
    }

    self.input_bytes = null;
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

pub fn hasCapacity(self: *const Outbox) bool {
    return self.len < outbox_support.capacity;
}

/// Reports how many complete messages the bounded queue can still own.
///
/// ```zig
/// const available = outbox.availableCapacity();
/// ```
pub fn availableCapacity(self: *const Outbox) usize {
    return outbox_support.capacity - @as(usize, self.len);
}

/// Copies the stable counters needed by client telemetry.
///
/// ```zig
/// const snapshot = outbox.snapshot();
/// ```
pub fn snapshot(self: *const Outbox) Snapshot {
    return .{
        .depth = self.len,
        .high_water = self.stats.high_water,
        .saturated = self.stats.saturated,
        .coalesced_input = self.stats.coalesced_input,
        .coalesced_resize = self.stats.coalesced_resize,
        .coalesced_ack = self.stats.coalesced_ack,
        .coalesced_client_layout = self.stats.coalesced_client_layout,
    };
}

/// Retains a completion outside the small per-message metadata. Example: `try outbox.pushClientCompletion(reply);`
/// Queues the ordered bootstrap after host negotiation. Capacity is checked
/// before any frame is queued.
///
/// ```zig
/// try model.to_runtime.pushBootstrap(.{ .graphics_shared = true, .client_identity = identity });
/// ```
pub fn pushBootstrap(self: *Outbox, request: RuntimeBootstrap) !void {
    if (self.availableCapacity() < 3) {
        return error.ClientOutboxFull;
    }

    try self.push(.{ .configure_graphics = .{ .shared = request.graphics_shared } });
    try self.push(.{ .configure_terminal_colors = request.terminal_colors });
    try self.push(.{ .request_runtime_state = .{ .client_identity = request.client_identity } });
}

pub fn pushClientCompletion(self: *Outbox, reply: core.ClientCommand) !void {
    try reply.validateWire();
    const index = try self.reserve();
    const encoded = core.encodeCompleteClientCommand(self.payloadAt(index), reply) catch unreachable;
    self.item_launch_cwd[index] = null;
    self.items[index] = .{ .complete_client_command = @intCast(encoded.len) };
}

pub fn push(self: *Outbox, message: outbox_support.Message) !void {
    switch (message) {
        .pane_resize => |resize| return self.pushResize(resize),
        .frame_ack => |ack| return self.pushAck(ack),
        .query_history => |query| {
            if (query.offset == 0 and query.snapshot_id == 0 and query.entry_id == 0) {
                if (self.mutableTailIndex()) |index| {
                    switch (self.items[index]) {
                        .query_history => |old| {
                            if (old.offset == 0 and old.snapshot_id == 0 and old.entry_id == 0) {
                                self.items[index] = message;
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
    try self.append(message);
}

pub fn pushInput(self: *Outbox, pane_id: core.PaneId, bytes: []const u8) !void {
    if (bytes.len == 0 or bytes.len > data.input_limits.max_encoded_bytes) {
        return error.InvalidInputLength;
    }
    if (self.mutableTailIndex()) |index| {
        switch (self.items[index]) {
            .pane_input => |*input| {
                if (input.pane_id == pane_id and
                    bytes.len <= self.payloadAt(index).len - input.len)
                {
                    @memcpy(self.payloadAt(index)[input.len..][0..bytes.len], bytes);
                    input.len += @intCast(bytes.len);
                    self.stats.coalesced_input +|= 1;
                    return;
                }
            },
            else => {},
        }
    }
    const index = try self.reserve();
    self.item_launch_cwd[index] = null;
    self.items[index] = .{ .pane_input = .{
        .pane_id = pane_id,
        .len = @intCast(bytes.len),
    } };
    @memcpy(self.payloadAt(index)[0..bytes.len], bytes);
}

/// Owns one prompt in the existing slot byte storage without coalescing turns.
/// Example: `try outbox.pushAgentPrompt(prompt);`
pub fn pushAgentPrompt(self: *Outbox, prompt: core.AgentPrompt) !void {
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

    const index = try self.reserve();
    self.item_launch_cwd[index] = null;
    self.items[index] = .{ .agent_prompt = .{
        .request_id = prompt.request_id,
        .pane_id = prompt.pane_id,
        .pane_generation = prompt.pane_generation,
        .len = @intCast(prompt.text.len),
        .options = prompt.options,
        .image_count = prompt.images.count,
    } };
    @memcpy(self.payloadAt(index)[0..prompt.text.len], prompt.text);
    var offset = prompt.text.len;
    for (prompt.images.storage[0..prompt.images.count], 0..) |path, image_index| {
        self.items[index].agent_prompt.image_lengths[image_index] = @intCast(path.len);
        @memcpy(self.payloadAt(index)[offset..][0..path.len], path);
        offset += path.len;
    }
}

/// Owns cursors in the existing outbound byte slot without per-input allocation.
/// Example: `try outbox.pushAgentHistory(query);`
pub fn pushAgentHistory(self: *Outbox, query: core.QueryAgentHistory) !void {
    _ = try core.AgentHistoryCursor.init(query.cursor);
    _ = try core.AgentHistoryCursor.init(query.anchor);
    _ = try core.AgentHistoryCursor.init(query.anchor_turn);
    if (query.cursor.len + query.anchor.len + query.anchor_turn.len > data.input_limits.max_encoded_bytes) {
        return error.InvalidAgentHistoryCursor;
    }
    const index = try self.reserve();
    self.item_launch_cwd[index] = null;
    self.items[index] = .{ .query_agent_history = .{ .request_id = query.request_id, .pane_id = query.pane_id, .pane_generation = query.pane_generation, .view_generation = query.view_generation, .cursor_len = @intCast(query.cursor.len), .anchor_len = @intCast(query.anchor.len), .anchor_turn_len = @intCast(query.anchor_turn.len), .direction = query.direction } };
    @memcpy(self.payloadAt(index)[0..query.cursor.len], query.cursor);
    @memcpy(self.payloadAt(index)[query.cursor.len..][0..query.anchor.len], query.anchor);
    @memcpy(self.payloadAt(index)[query.cursor.len + query.anchor.len ..][0..query.anchor_turn.len], query.anchor_turn);
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
pub fn pushInputBatch(self: *Outbox, pane_id: core.PaneId, bytes: []const u8) !void {
    if (bytes.len == 0 or bytes.len > core.max_history_command_bytes + 13) {
        return error.InvalidInputLength;
    }

    const count = (bytes.len + data.input_limits.max_encoded_bytes - 1) / data.input_limits.max_encoded_bytes;
    if (self.availableCapacity() < count) {
        return error.ClientOutboxFull;
    }

    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + data.input_limits.max_encoded_bytes, bytes.len);
        try self.pushInput(pane_id, bytes[offset..end]);
        offset = end;
    }
}

pub fn pushRename(self: *Outbox, rename: core.RenameTab) !void {
    if (rename.label.len == 0 or rename.label.len > core.max_tab_label_bytes) {
        return error.InvalidTabLabel;
    }

    var owned: OwnedRename = .{
        .request_id = rename.request_id,
        .location = rename.location,
        .len = @intCast(rename.label.len),
    };
    @memcpy(owned.label[0..rename.label.len], rename.label);
    try self.append(.{ .rename_tab = owned });
}

pub fn pushWorkspaceRename(self: *Outbox, rename: core.RenameWorkspace) !void {
    if (rename.name.len == 0 or rename.name.len > core.max_tab_label_bytes) {
        return error.InvalidWorkspaceName;
    }
    var owned: OwnedWorkspaceRename = .{
        .request_id = rename.request_id,
        .workspace = rename.workspace,
        .len = @intCast(rename.name.len),
    };
    @memcpy(owned.name[0..rename.name.len], rename.name);
    try self.append(.{ .rename_workspace = owned });
}

pub fn pushCreateWorkspace(self: *Outbox, request: core.CreateWorkspace) !void {
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
    try self.append(.{ .create_workspace = owned });
}

pub fn pushCreateTab(self: *Outbox, request: core.CreateTab) !void {
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
    try self.append(.{ .create_tab = owned });
}

pub fn pushNotification(self: *Outbox, request: core.ShowNotification) !void {
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
    try self.append(.{ .show_notification = owned });
}

/// Encodes and coalesces the latest complete client layout without
/// retaining slices into the mutable model.
///
/// ```zig
/// try outbox.pushClientLayout(update);
/// ```
pub fn pushClientLayout(self: *Outbox, update: core.ClientLayoutUpdate) !void {
    var offset: usize = 0;
    const mutable_len = self.len - @intFromBool(self.send_pending);
    while (offset < mutable_len) : (offset += 1) {
        const index = (@as(usize, self.head) + self.len - 1 - offset) % outbox_support.capacity;
        switch (self.items[index]) {
            .client_layout => |slot_index| {
                const slot = &self.client_layouts[slot_index];
                var scratch: [core.max_client_layout_wire_bytes]u8 = undefined;
                const encoded = try core.encodeClientLayoutUpdate(&scratch, update);
                @memcpy(slot.bytes[0..encoded.len], encoded);
                slot.len = @intCast(encoded.len);
                self.stats.coalesced_client_layout +|= 1;
                return;
            },
            else => break,
        }
    }

    const slot_index = try self.claimClientLayout(update);
    errdefer self.releaseClientLayoutSlot(slot_index);
    try self.append(.{ .client_layout = slot_index });
}

pub fn peek(self: *const Outbox) ?*const outbox_support.Message {
    if (self.len == 0) {
        return null;
    }
    return &self.items[self.head];
}

/// Claims the next queued message: encodes it into `buffer` and marks
/// the send in flight. Null while a send is already in flight or the
/// queue is empty. The claim ends in exactly one of `popSent` (the
/// scheduler delivered it) or `sendFailed` (it never left).
pub fn beginSend(self: *Outbox, buffer: []u8) !?[]const u8 {
    if (self.send_pending or self.len == 0) {
        return null;
    }
    const payload = try self.encodeNext(buffer);
    self.send_pending = true;
    return payload;
}

/// The scheduler refused the claimed send; the message stays queued.
pub fn sendFailed(self: *Outbox) void {
    std.debug.assert(self.send_pending);
    self.send_pending = false;
}

/// Releases one completed send claim. A failed socket write retains the
/// queued message for terminal cleanup and propagates its error.
///
/// ```zig
/// try outbox.finishSend(result);
/// ```
pub fn finishSend(self: *Outbox, result: anyerror!void) !void {
    result catch |err| {
        self.sendFailed();

        return err;
    };

    self.popSent();
}

/// True while a claimed send has neither completed nor failed.
pub fn inFlight(self: *const Outbox) bool {
    return self.send_pending;
}

pub fn popSent(self: *Outbox) void {
    std.debug.assert(self.send_pending);
    std.debug.assert(self.len != 0);
    self.releaseLaunchCwd(self.head);
    self.releaseClientLayout(self.head);
    self.send_pending = false;
    self.head = @intCast((@as(usize, self.head) + 1) % outbox_support.capacity);
    self.len -= 1;
}

fn encodeNext(self: *const Outbox, buffer: []u8) ![]const u8 {
    const message = self.peek() orelse return error.OutboxEmpty;
    return switch (message.*) {
        .open_pane => |value| {
            var owned = value;
            if (owned.launch) |*launch| {
                launch.cwd = self.launchCwd(self.head);
            }
            return core.encodeOpenPane(buffer, owned);
        },
        .pane_input => |value| core.encodePaneInput(buffer, .{
            .pane_id = value.pane_id,
            .bytes = self.payloadAt(self.head)[0..value.len],
        }),
        .pane_resize => |value| core.encodePaneResize(buffer, value),
        .frame_ack => |value| core.encodeFrameAck(buffer, value),
        .request_snapshot => |value| core.encodeRequestSnapshot(buffer, value),
        .detach_pane => |value| core.encodeDetachPane(buffer, value),
        .request_tab_snapshot => |value| core.encodeRequestTabSnapshot(buffer, value),
        .create_pane => |value| {
            var scratch: [core.max_argument_count][]const u8 = undefined;
            var owned = value.view(self.payloadAt(self.head), &scratch);
            owned.launch.cwd = self.launchCwd(self.head);
            return core.encodeCreatePane(buffer, owned);
        },
        .close_pane => |value| core.encodeClosePane(buffer, value),
        .request_workspace_snapshot => |value| core.encodeRequestWorkspaceSnapshot(buffer, value),
        .create_tab => |*value| encode: {
            var scratch: [core.max_argument_count][]const u8 = undefined;
            var owned = value.view(self.payloadAt(self.head), &scratch);
            owned.launch.cwd = self.launchCwd(self.head);
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
            value.view(self.launchCwd(self.head)),
        ),
        .rename_workspace => |*value| core.encodeRenameWorkspace(buffer, .{
            .request_id = value.request_id,
            .workspace = value.workspace,
            .name = value.slice(),
        }),
        .set_pane_viewport => |value| core.encodeSetPaneViewport(buffer, value),
        .copy_selection => |value| core.encodeCopySelection(buffer, value),
        .show_notification => |*value| core.encodeShowNotification(buffer, value.view()),
        .client_layout => |slot| self.client_layouts[slot].slice(),
        .acknowledge_agent => |value| core.encodeAcknowledgeAgent(buffer, value),
        .search_pane => |*value| core.encodeSearchPane(buffer, value.view()),
        .query_history => |*value| core.encodeQueryHistory(buffer, value.view()),
        .delete_history => |value| core.encodeDeleteHistory(buffer, value),
        .read_history_output => |value| core.encodeReadHistoryOutput(buffer, value),
        .suggest_command => |*value| core.encodeSuggestCommand(buffer, value.view()),
        .complete_client_command => |length| self.payloadAt(self.head)[0..length],
        .open_editor => |value| encode: {
            var request = value;
            const bytes = self.payloadAt(self.head);
            request.editor = bytes[0..value.editor.len];
            request.path = bytes[value.editor.len..][0..value.path.len];
            break :encode core.encodeOpenEditor(buffer, request);
        },
        .complete_pane_focus => |value| core.encodeCompletePaneFocus(buffer, value),
        .agent_prompt => |*value| core.encodeAgentPrompt(buffer, value.view(self.payloadAt(self.head))),
        .agent_interrupt => |value| core.encodeAgentInterrupt(buffer, value),
        .agent_resume => |value| core.encodeAgentResume(buffer, value),
        .agent_approval => |value| core.encodeAgentApproval(buffer, value),
        .query_change_review, .change_review_command => |len| self.payloadAt(self.head)[0..len],
        .query_agent_thread => |value| core.encodeQueryAgentThread(buffer, value),
        .query_agent_history => |*value| core.encodeQueryAgentHistory(buffer, value.view(self.payloadAt(self.head))),
    };
}

fn append(self: *Outbox, message: outbox_support.Message) !void {
    const launch_slot = if (outbox_support.messageLaunchCwd(message)) |cwd|
        try self.claimLaunchCwd(cwd)
    else
        null;
    errdefer if (launch_slot) |slot| self.releaseLaunchSlot(slot);
    const index = try self.reserve();
    errdefer self.len -= 1;
    var owned = message;
    if (owned == .open_editor) {
        try owned.open_editor.validateWire();
        const request = owned.open_editor;
        if (request.editor.len + request.path.len > data.input_limits.max_encoded_bytes) {
            return error.InvalidEditorTarget;
        }

        @memcpy(self.payloadAt(index)[0..request.editor.len], request.editor);
        @memcpy(self.payloadAt(index)[request.editor.len..][0..request.path.len], request.path);
        owned.open_editor.editor = self.payloadAt(index)[0..request.editor.len];
        owned.open_editor.path = self.payloadAt(index)[request.editor.len..][0..request.path.len];
    } else if (owned == .create_pane) {
        try owned.create_pane.ownArguments(self.payloadAt(index));
    } else if (owned == .create_tab) {
        try owned.create_tab.ownArguments(self.payloadAt(index));
    }

    self.item_launch_cwd[index] = launch_slot;
    self.items[index] = owned;
}

fn claimLaunchCwd(self: *Outbox, cwd: []const u8) !u8 {
    if (cwd.len == 0 or cwd.len > core.max_cwd_bytes) {
        return error.InvalidCwd;
    }
    for (&self.launch_cwds, 0..) |*slot, index| {
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

fn launchCwd(self: *const Outbox, item_index: usize) []const u8 {
    const slot = self.item_launch_cwd[item_index] orelse unreachable;
    return self.launch_cwds[slot].slice();
}

fn releaseLaunchCwd(self: *Outbox, item_index: usize) void {
    const slot = self.item_launch_cwd[item_index] orelse return;
    self.releaseLaunchSlot(slot);
    self.item_launch_cwd[item_index] = null;
}

fn releaseLaunchSlot(self: *Outbox, slot_index: u8) void {
    const slot = &self.launch_cwds[slot_index];
    std.debug.assert(slot.used);
    slot.len = 0;
    slot.used = false;
}

fn claimClientLayout(self: *Outbox, update: core.ClientLayoutUpdate) !u8 {
    for (&self.client_layouts, 0..) |*slot, index| {
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

fn releaseClientLayout(self: *Outbox, item_index: usize) void {
    const slot = switch (self.items[item_index]) {
        .client_layout => |slot_index| slot_index,
        else => return,
    };

    self.releaseClientLayoutSlot(slot);
}

fn releaseClientLayoutSlot(self: *Outbox, slot_index: u8) void {
    const slot = &self.client_layouts[slot_index];
    std.debug.assert(slot.used);
    slot.len = 0;
    slot.used = false;
}

fn reserve(self: *Outbox) !usize {
    if (self.len == outbox_support.capacity) {
        self.stats.saturated +|= 1;
        return error.ClientOutboxFull;
    }
    const index = (@as(usize, self.head) + self.len) % outbox_support.capacity;
    self.len += 1;
    self.stats.high_water = @max(self.stats.high_water, self.len);
    return index;
}

fn tailIndex(self: *const Outbox) ?usize {
    if (self.len == 0) {
        return null;
    }
    return (@as(usize, self.head) + self.len - 1) % outbox_support.capacity;
}

fn mutableTailIndex(self: *const Outbox) ?usize {
    const index = self.tailIndex() orelse return null;
    if (self.send_pending and index == self.head) {
        return null;
    }
    return index;
}

fn pushResize(self: *Outbox, resize: core.PaneResize) !void {
    var offset: usize = 0;
    const mutable_len = self.len - @intFromBool(self.send_pending);
    while (offset < mutable_len) : (offset += 1) {
        const index = (@as(usize, self.head) + self.len - 1 - offset) % outbox_support.capacity;
        switch (self.items[index]) {
            .pane_resize => |*pending| {
                if (pending.pane_id == resize.pane_id) {
                    pending.* = resize;
                    self.stats.coalesced_resize +|= 1;
                    return;
                }
            },
            else => break,
        }
    }
    try self.append(.{ .pane_resize = resize });
}

fn pushAck(self: *Outbox, ack: core.FrameAck) !void {
    var offset: usize = 0;
    const mutable_len = self.len - @intFromBool(self.send_pending);
    while (offset < mutable_len) : (offset += 1) {
        const index = (@as(usize, self.head) + self.len - 1 - offset) % outbox_support.capacity;
        switch (self.items[index]) {
            .frame_ack => |*pending| {
                if (pending.pane_id == ack.pane_id) {
                    pending.* = ack;
                    self.stats.coalesced_ack +|= 1;
                    return;
                }
            },
            else => break,
        }
    }
    try self.append(.{ .frame_ack = ack });
}

/// Bootstrap messages are small; a real sender encodes into a whole frame.
const bootstrap_send_bytes = 64 * 1024;

test "runtime bootstrap queues colors before subscribing to the initial layout" {
    var outbox: Outbox = try .init(std.testing.allocator);
    defer outbox.deinit(std.testing.allocator);
    var buffer: [bootstrap_send_bytes]u8 = undefined;

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

/// What a client tells the runtime right after host negotiation.
const RuntimeBootstrap = struct {
    graphics_shared: bool,
    client_identity: core.ClientIdentity,
    terminal_colors: core.TerminalColors = .{},
};
