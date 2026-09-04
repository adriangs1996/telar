//! Application policy for requesting one runtime attachment per detached pane
//! that has visible content.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../../../workspace/root.zig");
const client_model = @import("../../model/root.zig");

const schema = core.schema;
const tabs_mod = workspace_capability.tabs;
const ui = core.ui;

pub const PaneAttachmentRequest = struct {
    pane_id: schema.PaneId,
    location: schema.TabLocation,
    size: schema.TerminalSize,
};

pub const Effects = struct {
    context: *anyopaque,
    attachment_pending: *const fn (*anyopaque, schema.PaneId) bool,
    request_attachment: *const fn (*anyopaque, PaneAttachmentRequest) anyerror!void,
};

pub const RequestPaneAttachmentsHandler = struct {
    effects: Effects,

    /// Requests an attachment for each detached pane of `tab` that has visible
    /// content in `area`, and returns how many it requested. A pane with a
    /// request already pending is left alone. A pane without content cannot
    /// carry a terminal size, so it stays detached until the geometry changes
    /// and a later offer finds room for it. The runtime owns membership, so an
    /// unattachable pane is a degraded view, never a failure.
    ///
    /// ```zig
    /// const count = try handler.execute(tab, area);
    /// ```
    pub fn execute(handler: *RequestPaneAttachmentsHandler, tab: *tabs_mod.Tab, area: ui.Rect) !usize {
        var count: usize = 0;
        var panes = tab.model.paneIterator();
        while (panes.next()) |pane| {
            if (pane.attached or handler.effects.attachment_pending(handler.effects.context, pane.id)) {
                continue;
            }

            const size = tab.model.contentSize(pane.id, area) orelse continue;
            try handler.effects.request_attachment(handler.effects.context, .{
                .pane_id = pane.id,
                .location = tab.location,
                .size = size,
            });
            count += 1;
        }

        return count;
    }
};

pub const RequestActivePaneAttachmentsHandler = struct {
    model: *client_model.Model,
    effects: Effects,

    /// Selects the active tab once its canonical snapshot has loaded and
    /// requests the attachments its detached visible panes are missing. Used
    /// after a geometry change, so a pane skipped by a crowded layout attaches
    /// as soon as it fits.
    ///
    /// ```zig
    /// const count = try handler.execute(area);
    /// ```
    pub fn execute(handler: *RequestActivePaneAttachmentsHandler, area: ui.Rect) !usize {
        const active = handler.model.workspace.active() orelse return 0;
        if (!active.snapshot_loaded) {
            return 0;
        }

        var request: RequestPaneAttachmentsHandler = .{ .effects = handler.effects };
        return request.execute(active, area);
    }
};

const TestingModel = struct {
    model: *client_model.Model,
    location: schema.TabLocation,
    root: schema.PaneId,
    discovered: schema.PaneId,

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
        try model.workspace.bootstrap(.{ .pane_id = root, .location = location, .size = .{ .cols = 20, .rows = 5 } });

        return .{ .model = model, .location = location, .root = root, .discovered = @enumFromInt(2) };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }

    fn reconcile(testing: *TestingModel, area: ui.Rect) !void {
        _ = try testing.model.reconcileTab(.{
            .location = testing.location,
            .panes = &.{ testing.root, testing.discovered },
        }, area);
    }
};

const Capture = struct {
    pending: ?schema.PaneId = null,
    requests: [4]PaneAttachmentRequest = undefined,
    request_count: usize = 0,

    fn effects(capture: *Capture) Effects {
        return .{
            .context = capture,
            .attachment_pending = attachmentPending,
            .request_attachment = requestAttachment,
        };
    }

    fn attachmentPending(raw_context: *anyopaque, pane_id: schema.PaneId) bool {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        return capture.pending == pane_id;
    }

    fn requestAttachment(raw_context: *anyopaque, request: PaneAttachmentRequest) !void {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        capture.requests[capture.request_count] = request;
        capture.request_count += 1;
    }
};

const wide: ui.Rect = .{ .w = 40, .h = 10 };
const cramped: ui.Rect = .{ .w = 4, .h = 3 };

test "RequestPaneAttachmentsHandler requests only detached panes with content" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    try testing.reconcile(wide);
    var capture: Capture = .{};
    var use_case: RequestActivePaneAttachmentsHandler = .{ .model = testing.model, .effects = capture.effects() };

    try std.testing.expectEqual(@as(usize, 1), try use_case.execute(wide));

    try std.testing.expectEqual(testing.discovered, capture.requests[0].pane_id);
    try std.testing.expectEqual(testing.location, capture.requests[0].location);
    try std.testing.expectEqual(@as(u16, 18), capture.requests[0].size.cols);
}

test "RequestPaneAttachmentsHandler skips a pending request and an empty pane" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    try testing.reconcile(cramped);
    var capture: Capture = .{};
    var use_case: RequestActivePaneAttachmentsHandler = .{ .model = testing.model, .effects = capture.effects() };

    try std.testing.expectEqual(@as(usize, 0), try use_case.execute(cramped));

    capture.pending = testing.discovered;
    try std.testing.expectEqual(@as(usize, 0), try use_case.execute(wide));
    capture.pending = null;
    try std.testing.expectEqual(@as(usize, 1), try use_case.execute(wide));
    try std.testing.expectEqual(testing.discovered, capture.requests[0].pane_id);
}

test "RequestActivePaneAttachmentsHandler waits for the canonical snapshot" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{};
    var use_case: RequestActivePaneAttachmentsHandler = .{ .model = testing.model, .effects = capture.effects() };

    try std.testing.expectEqual(@as(usize, 0), try use_case.execute(wide));
    try std.testing.expectEqual(@as(usize, 0), capture.request_count);
}
