//! Application policy for reserving every bounded resource required by one
//! provisional workspace handoff before it produces effects.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../model/root.zig");
const tab_attachment_retirement = @import("../tabs/tab_attachment_retirement.zig");

const schema = core.schema;

pub const RequestCapacity = struct {
    context: *anyopaque,
    ensure: *const fn (*anyopaque, u64) anyerror!void,
};

pub const DeliveryCapacity = struct {
    context: *anyopaque,
    available: *const fn (*anyopaque) usize,
};

pub const PrepareWorkspaceHandoffHandler = struct {
    model: *client_model.Model,
    requests: RequestCapacity,
    deliveries: DeliveryCapacity,
    pending_attachments: tab_attachment_retirement.PendingAttachments,

    /// Reserves one open request, its recovery identity and every outbound
    /// delivery required to retire the current workspace without effects.
    ///
    /// ```zig
    /// try handler.execute();
    /// ```
    pub fn execute(handler: *const PrepareWorkspaceHandoffHandler) !void {
        try handler.requests.ensure(handler.requests.context, 2);

        const required_capacity = try handler.requiredDeliveryCapacity();
        if (required_capacity > handler.deliveries.available(handler.deliveries.context)) {
            return error.ClientOutboxFull;
        }
    }

    fn requiredDeliveryCapacity(handler: *const PrepareWorkspaceHandoffHandler) !usize {
        var required: usize = 1;

        var tabs = handler.model.workspace.tabIterator();
        while (tabs.next()) |tab| {
            const plan = try handler.model.planTabDetachment(tab.location);
            required += tab_attachment_retirement.requiredDeliveryCapacity(
                &plan,
                handler.pending_attachments,
            );
        }

        return required;
    }
};

const Event = union(enum) {
    ensure_requests: u64,
    attachment_pending: schema.PaneId,
    available_deliveries,
};

const TestingModel = struct {
    model: *client_model.Model,
    root: schema.PaneId,
    sibling: schema.PaneId,
    other_root: schema.PaneId,

    fn init() !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
        const active: schema.TabLocation = .{
            .workspace = workspace,
            .tab_id = @enumFromInt(1),
        };
        const other: schema.TabLocation = .{
            .workspace = workspace,
            .tab_id = @enumFromInt(2),
        };
        const root: schema.PaneId = @enumFromInt(1);
        const sibling: schema.PaneId = @enumFromInt(2);
        const other_root: schema.PaneId = @enumFromInt(3);
        try model.workspace.bootstrap(root, active, .{ .cols = 40, .rows = 10 });
        try model.workspace.active().?.model.split(.{ .existing_pane = root, .new_pane = sibling, .location = active, .axis = .horizontal, .area = .{ .w = 40, .h = 10 } });
        _ = try model.workspace.addCreated(.{
            .location = other,
            .position = 1,
            .label = "other",
            .root_pane_id = other_root,
        }, .{ .cols = 40, .rows = 10 });
        if (!model.workspace.select(active.tab_id)) {
            return error.ActiveTabNotRestored;
        }
        if (!model.workspace.active().?.model.focusPane(root)) {
            return error.ActiveFocusNotRestored;
        }

        const root_pane = model.workspace.findPane(root).?;
        root_pane.input_modes.bracketed_paste = true;
        root_pane.input_modes.focus_events = true;
        model.workspace.findPane(sibling).?.attached = false;
        _ = model.beginPanePaste().?;
        _ = model.syncReportedPaneFocus().?;

        return .{
            .model = model,
            .root = root,
            .sibling = sibling,
            .other_root = other_root,
        };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }
};

const Capture = struct {
    model: *client_model.Model,
    pending_pane: ?schema.PaneId,
    available: usize,
    request_failure: ?anyerror = null,
    events: [5]Event = undefined,
    event_count: usize = 0,
    queries_observed_unchanged: bool = true,

    fn handler(capture: *Capture) PrepareWorkspaceHandoffHandler {
        return .{
            .model = capture.model,
            .requests = .{
                .context = capture,
                .ensure = ensureRequests,
            },
            .deliveries = .{
                .context = capture,
                .available = availableDeliveries,
            },
            .pending_attachments = .{
                .context = capture,
                .pending = attachmentPending,
            },
        };
    }

    fn ensureRequests(context: *anyopaque, count: u64) !void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.append(.{ .ensure_requests = count });
        if (capture.request_failure) |failure| {
            return failure;
        }
    }

    fn availableDeliveries(context: *anyopaque) usize {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.append(.available_deliveries);

        return capture.available;
    }

    fn attachmentPending(context: *anyopaque, pane_id: schema.PaneId) bool {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.queries_observed_unchanged = capture.queries_observed_unchanged and
            capture.model.panePasteActive() and
            capture.model.reportedPaneFocus() != null and
            capture.model.workspace.findPane(pane_id) != null;
        capture.append(.{ .attachment_pending = pane_id });

        return capture.pending_pane == pane_id;
    }

    fn append(capture: *Capture, event: Event) void {
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn eventSlice(capture: *const Capture) []const Event {
        return capture.events[0..capture.event_count];
    }
};

fn expectModelUnchanged(testing: *const TestingModel) !void {
    try std.testing.expect(testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() != null);
    try std.testing.expect(testing.model.workspace.findPane(testing.root).?.attached);
    try std.testing.expect(!testing.model.workspace.findPane(testing.sibling).?.attached);
    try std.testing.expect(testing.model.workspace.findPane(testing.other_root).?.attached);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "PrepareWorkspaceHandoffHandler accepts exact bounded capacity without effects" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{
        .model = testing.model,
        .pending_pane = testing.sibling,
        .available = 6,
    };
    const handler = capture.handler();

    try handler.execute();

    try std.testing.expectEqualDeep(&[_]Event{
        .{ .ensure_requests = 2 },
        .{ .attachment_pending = testing.root },
        .{ .attachment_pending = testing.sibling },
        .{ .attachment_pending = testing.other_root },
        .available_deliveries,
    }, capture.eventSlice());
    try std.testing.expect(capture.queries_observed_unchanged);
    try expectModelUnchanged(&testing);
}

test "PrepareWorkspaceHandoffHandler rejects delivery exhaustion without effects" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{
        .model = testing.model,
        .pending_pane = testing.sibling,
        .available = 5,
    };
    const handler = capture.handler();

    try std.testing.expectError(error.ClientOutboxFull, handler.execute());

    try std.testing.expectEqualDeep(&[_]Event{
        .{ .ensure_requests = 2 },
        .{ .attachment_pending = testing.root },
        .{ .attachment_pending = testing.sibling },
        .{ .attachment_pending = testing.other_root },
        .available_deliveries,
    }, capture.eventSlice());
    try std.testing.expect(capture.queries_observed_unchanged);
    try expectModelUnchanged(&testing);
}

test "PrepareWorkspaceHandoffHandler rejects request exhaustion before delivery queries" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{
        .model = testing.model,
        .pending_pane = testing.sibling,
        .available = 6,
        .request_failure = error.RequestIdExhausted,
    };
    const handler = capture.handler();

    try std.testing.expectError(error.RequestIdExhausted, handler.execute());

    try std.testing.expectEqualDeep(&[_]Event{
        .{ .ensure_requests = 2 },
    }, capture.eventSlice());
    try expectModelUnchanged(&testing);
}
