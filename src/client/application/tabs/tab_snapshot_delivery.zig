//! Application policy for delivering client resources after one canonical tab
//! snapshot commit.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../../workspace/root.zig");
const client_model = @import("../../root.zig").model;
const pane_attachment_requests = @import("../panes/root.zig").pane_attachment_requests;
const pane_geometry_delivery = @import("../panes/root.zig").pane_geometry_delivery;
const pane_resource_release = @import("../panes/root.zig").pane_resource_release;

pub const schema = core.schema;
pub const tabs_mod = workspace_capability.tabs;
pub const ui = core.ui;

pub const PaneAttachmentRequest = pane_attachment_requests.PaneAttachmentRequest;

pub const Effects = @import("TabSnapshotDeliveryEffects.zig");

pub const DeliverTabSnapshotHandler = @import("DeliverTabSnapshotHandler.zig");

pub const Event = union(enum) {
    ignore_pane: schema.PaneId,
    clear_graphics: schema.PaneId,
    synchronize_active_resources,
    resize: schema.PaneId,
    attachment_pending: schema.PaneId,
    request_attachment: schema.PaneId,
};

pub const Failure = enum {
    none,
    active_resources,
    resize,
    attachment,
};

const TestingModel = @import("TabSnapshotDeliveryTestingModel.zig");

const EffectsCapture = @import("TabSnapshotDeliveryEffectsCapture.zig");

fn deliveryHandler(capture: *EffectsCapture) DeliverTabSnapshotHandler {
    return .{
        .model = capture.model,
        .geometry_effects = capture.geometryEffects(),
        .effects = capture.effects(),
    };
}

test "DeliverTabSnapshotHandler synchronizes active resources before geometry and attachments" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    const reconciliation = try testing.reconcileMany();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .reconciliation = &reconciliation,
    };
    var use_case = deliveryHandler(&capture);

    try use_case.execute(&reconciliation);

    try std.testing.expectEqualDeep(&[_]Event{
        .synchronize_active_resources,
        .{ .resize = testing.root },
        .{ .attachment_pending = testing.discovered },
        .{ .request_attachment = testing.discovered },
    }, capture.eventSlice());
    try std.testing.expectEqual(testing.discovered, capture.attachment.?.pane_id);
    try std.testing.expectEqualDeep(testing.target, capture.attachment.?.location);
    try std.testing.expect(capture.attachment.?.size.cols > 0);
    try std.testing.expect(capture.attachment.?.size.rows > 0);
    try std.testing.expect(capture.committed_state_observed);
}

test "DeliverTabSnapshotHandler releases retired resources before active synchronization" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    const all = [_]schema.PaneId{ testing.root, testing.discovered, testing.other_pane };
    _ = try testing.reconcile(&all);
    const tab = testing.model.workspace.find(testing.target.tab_id).?;
    try tab.model.markAttached(testing.discovered, 1);
    try std.testing.expect(tab.model.focusPane(testing.discovered));
    const pane = tab.model.find(testing.discovered).?;
    pane.input_modes.bracketed_paste = true;
    pane.input_modes.focus_events = true;
    _ = testing.model.beginPanePaste().?;
    _ = testing.model.syncReportedPaneFocus().?;
    const reconciliation = try testing.reconcileRoot();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .reconciliation = &reconciliation,
    };
    var use_case = deliveryHandler(&capture);

    try use_case.execute(&reconciliation);

    try std.testing.expectEqualDeep(&[_]Event{
        .{ .ignore_pane = testing.discovered },
        .{ .clear_graphics = testing.discovered },
        .{ .ignore_pane = testing.other_pane },
        .{ .clear_graphics = testing.other_pane },
        .synchronize_active_resources,
        .{ .resize = testing.root },
    }, capture.eventSlice());
    try std.testing.expect(capture.resources_released_before_graphics);
    try std.testing.expect(!testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() == null);
}

test "DeliverTabSnapshotHandler preserves a pending attachment" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    const reconciliation = try testing.reconcileMany();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .reconciliation = &reconciliation,
        .pending_attachment = testing.discovered,
    };
    var use_case = deliveryHandler(&capture);

    try use_case.execute(&reconciliation);

    try std.testing.expectEqualDeep(&[_]Event{
        .synchronize_active_resources,
        .{ .resize = testing.root },
        .{ .attachment_pending = testing.discovered },
    }, capture.eventSlice());
    try std.testing.expectEqual(@as(?PaneAttachmentRequest, null), capture.attachment);
}

test "DeliverTabSnapshotHandler skips a detached pane without visible content" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    const reconciliation = try testing.reconcileIn(&testing.many, .{ .w = 4, .h = 3 });
    var capture: EffectsCapture = .{
        .model = testing.model,
        .reconciliation = &reconciliation,
    };
    var use_case = deliveryHandler(&capture);

    try use_case.execute(&reconciliation);

    try std.testing.expectEqualDeep(&[_]Event{
        .synchronize_active_resources,
        .{ .attachment_pending = testing.discovered },
    }, capture.eventSlice());
    try std.testing.expectEqual(@as(?PaneAttachmentRequest, null), capture.attachment);
    try std.testing.expect(!testing.model.workspace.find(testing.target.tab_id).?.model.find(testing.discovered).?.attached);
}

test "DeliverTabSnapshotHandler leaves inactive tab resources untouched" {
    var testing = try TestingModel.init(false);
    defer testing.deinit();
    const reconciliation = try testing.reconcileMany();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .reconciliation = &reconciliation,
    };
    var use_case = deliveryHandler(&capture);

    try use_case.execute(&reconciliation);

    try std.testing.expect(!reconciliation.active);
    try std.testing.expect(reconciliation.panes_changed);
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
    try std.testing.expectEqual(@as(u64, 0), testing.model.version().panes);
}

test "DeliverTabSnapshotHandler rejects stale topology layout and snapshot state" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    var reconciliation = try testing.reconcileMany();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .reconciliation = &reconciliation,
    };
    var use_case = deliveryHandler(&capture);

    testing.model.workspace_revision +%= 1;
    try std.testing.expectError(error.StaleTabReconciliation, use_case.execute(&reconciliation));
    testing.model.workspace_revision -%= 1;

    testing.model.tabs_revision +%= 1;
    try std.testing.expectError(error.StaleTabReconciliation, use_case.execute(&reconciliation));
    testing.model.tabs_revision -%= 1;

    testing.model.active_tab_revision +%= 1;
    try std.testing.expectError(error.StaleTabReconciliation, use_case.execute(&reconciliation));
    testing.model.active_tab_revision -%= 1;

    testing.model.panes_revision +%= 1;
    try std.testing.expectError(error.StaleTabReconciliation, use_case.execute(&reconciliation));
    testing.model.panes_revision -%= 1;

    reconciliation.active = !reconciliation.active;
    try std.testing.expectError(error.StaleTabReconciliation, use_case.execute(&reconciliation));
    reconciliation.active = !reconciliation.active;

    const tab = testing.model.workspace.find(testing.target.tab_id).?;
    tab.snapshot_loaded = false;
    try std.testing.expectError(error.StaleTabReconciliation, use_case.execute(&reconciliation));
    tab.snapshot_loaded = true;

    const focused = tab.model.layout.focused().?;
    const other = if (focused == testing.root) testing.discovered else testing.root;
    try std.testing.expect(tab.model.focusPane(other));
    try std.testing.expectError(error.StaleTabReconciliation, use_case.execute(&reconciliation));

    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "DeliverTabSnapshotHandler stops before geometry after active resource failure" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    const reconciliation = try testing.reconcileMany();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .reconciliation = &reconciliation,
        .failure = .active_resources,
    };
    var use_case = deliveryHandler(&capture);

    try std.testing.expectError(error.ActiveResourceSyncFailed, use_case.execute(&reconciliation));

    try std.testing.expectEqualDeep(&[_]Event{.synchronize_active_resources}, capture.eventSlice());
    try std.testing.expect(capture.committed_state_observed);
}

test "DeliverTabSnapshotHandler stops before attachments after geometry failure" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    const reconciliation = try testing.reconcileMany();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .reconciliation = &reconciliation,
        .failure = .resize,
    };
    var use_case = deliveryHandler(&capture);

    try std.testing.expectError(error.PaneResizeFailed, use_case.execute(&reconciliation));

    try std.testing.expectEqualDeep(&[_]Event{
        .synchronize_active_resources,
        .{ .resize = testing.root },
    }, capture.eventSlice());
    try std.testing.expect(capture.committed_state_observed);
}

test "DeliverTabSnapshotHandler preserves earlier effects after attachment failure" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    const reconciliation = try testing.reconcileMany();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .reconciliation = &reconciliation,
        .failure = .attachment,
    };
    var use_case = deliveryHandler(&capture);

    try std.testing.expectError(error.AttachmentRequestFailed, use_case.execute(&reconciliation));

    try std.testing.expectEqualDeep(&[_]Event{
        .synchronize_active_resources,
        .{ .resize = testing.root },
        .{ .attachment_pending = testing.discovered },
        .{ .request_attachment = testing.discovered },
    }, capture.eventSlice());
    try std.testing.expect(capture.committed_state_observed);
}
