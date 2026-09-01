//! Application policy for reserving every bounded resource required by one
//! provisional tab closure before it produces effects.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../model/root.zig");
const tab_attachment_retirement = @import("tab_attachment_retirement.zig");

const schema = core.schema;

pub const RequestCapacity = struct {
    context: *anyopaque,
    ensure: *const fn (*anyopaque, u64) anyerror!void,
};

pub const DeliveryCapacity = struct {
    context: *anyopaque,
    available: *const fn (*anyopaque) usize,
};

pub const PrepareTabCloseHandler = struct {
    requests: RequestCapacity,
    deliveries: DeliveryCapacity,
    pending_attachments: tab_attachment_retirement.PendingAttachments,

    /// Reserves one close request, its recovery identity and every outbound
    /// delivery required to retire the exact tab without changing state.
    ///
    /// ```zig
    /// try handler.execute(model, location);
    /// ```
    pub fn execute(handler: *const PrepareTabCloseHandler, model: *const client_model.Model, location: schema.TabLocation) !void {
        const plan = try model.planTabDetachment(location);

        try handler.requests.ensure(handler.requests.context, 2);

        const retirement_capacity = tab_attachment_retirement.requiredDeliveryCapacity(
            &plan,
            handler.pending_attachments,
        );
        const required_capacity = 1 + retirement_capacity;
        if (required_capacity > handler.deliveries.available(handler.deliveries.context)) {
            return error.ClientOutboxFull;
        }
    }
};

const Event = union(enum) {
    ensure_requests: u64,
    attachment_pending: schema.PaneId,
    available_deliveries,
};

const TestingModel = struct {
    model: *client_model.Model,
    location: schema.TabLocation,
    root: schema.PaneId,
    sibling: schema.PaneId,

    fn init() !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const location: schema.TabLocation = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        };
        const root: schema.PaneId = @enumFromInt(1);
        const sibling: schema.PaneId = @enumFromInt(2);
        try model.workspace.bootstrap(root, location, .{ .cols = 40, .rows = 10 });
        try model.workspace.active().?.model.split(root, sibling, location, .horizontal, .{ .w = 40, .h = 10 });
        if (!model.workspace.active().?.model.focusPane(root)) {
            return error.FocusNotChanged;
        }

        const root_pane = model.workspace.findPane(root).?;
        root_pane.input_modes.bracketed_paste = true;
        root_pane.input_modes.focus_events = true;
        model.workspace.findPane(sibling).?.attached = false;
        _ = model.beginPanePaste().?;
        _ = model.syncReportedPaneFocus().?;

        return .{
            .model = model,
            .location = location,
            .root = root,
            .sibling = sibling,
        };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }
};

const Capture = struct {
    pending_pane: ?schema.PaneId,
    available: usize,
    request_failure: ?anyerror = null,
    events: [4]Event = undefined,
    event_count: usize = 0,

    fn handler(capture: *Capture) PrepareTabCloseHandler {
        return .{
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

test "PrepareTabCloseHandler accepts the exact required capacity without effects" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{
        .pending_pane = testing.sibling,
        .available = 5,
    };
    const handler = capture.handler();

    try handler.execute(testing.model, testing.location);

    try std.testing.expectEqualDeep(&[_]Event{
        .{ .ensure_requests = 2 },
        .{ .attachment_pending = testing.root },
        .{ .attachment_pending = testing.sibling },
        .available_deliveries,
    }, capture.eventSlice());
    try std.testing.expect(testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() != null);
    try std.testing.expect(testing.model.workspace.findPane(testing.root).?.attached);
    try std.testing.expect(!testing.model.workspace.findPane(testing.sibling).?.attached);
}

test "PrepareTabCloseHandler rejects insufficient delivery capacity without effects" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{
        .pending_pane = testing.sibling,
        .available = 4,
    };
    const handler = capture.handler();

    try std.testing.expectError(error.ClientOutboxFull, handler.execute(testing.model, testing.location));

    try std.testing.expectEqual(@as(usize, 4), capture.event_count);
    try std.testing.expect(testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() != null);
    try std.testing.expect(testing.model.workspace.findPane(testing.root).?.attached);
}

test "PrepareTabCloseHandler stops on request exhaustion before delivery queries" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{
        .pending_pane = testing.sibling,
        .available = 5,
        .request_failure = error.RequestIdExhausted,
    };
    const handler = capture.handler();

    try std.testing.expectError(error.RequestIdExhausted, handler.execute(testing.model, testing.location));
    try std.testing.expectEqualDeep(&[_]Event{
        .{ .ensure_requests = 2 },
    }, capture.eventSlice());
}

test "PrepareTabCloseHandler rejects an unknown exact tab before port calls" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{
        .pending_pane = testing.sibling,
        .available = 5,
    };
    const handler = capture.handler();
    const missing: schema.TabLocation = .{
        .workspace = testing.location.workspace,
        .tab_id = @enumFromInt(9),
    };

    try std.testing.expectError(error.UnexpectedTab, handler.execute(testing.model, missing));
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}
