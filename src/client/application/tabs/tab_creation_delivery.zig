//! Application policy for delivering disposable client resources after one
//! committed tab creation.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../../workspace/root.zig");
const client_model = @import("../../root.zig").model;
const pane_focus_reporting = @import("../panes/root.zig").pane_focus_reporting;
const pane_paste = @import("../input/root.zig").pane_paste;
const tab_attachment_retirement = @import("tab_attachment_retirement.zig");

pub const schema = core.schema;
pub const tabs_mod = workspace_capability.tabs;

pub const Effects = @import("TabCreationDeliveryEffects.zig");

pub const DeliverTabCreationHandler = @import("DeliverTabCreationHandler.zig");

pub const Event = union(enum) {
    paste_finish: schema.PaneId,
    focus_out: schema.PaneId,
    attachment_pending: schema.PaneId,
    detach: schema.PaneId,
    retire_attachment: schema.PaneId,
    hide_graphics: schema.PaneId,
    synchronize_active_resources,
};

pub const Failure = enum {
    none,
    paste,
    focus,
    second_detach,
    active_resources,
};

const TestingModel = @import("TabCreationDeliveryTestingModel.zig");

const EffectsCapture = @import("TabCreationDeliveryEffectsCapture.zig");

fn captureFor(testing: *TestingModel, creation: client_model.TabCreation) EffectsCapture {
    return .{
        .model = testing.model,
        .creation = creation,
        .previous_root = testing.previous_root,
        .previous_sibling = testing.previous_sibling,
    };
}

fn deliveryHandler(testing: *TestingModel, capture: *EffectsCapture) DeliverTabCreationHandler {
    return .{
        .model = testing.model,
        .paste_effects = capture.pasteEffects(),
        .focus_effects = capture.focusEffects(),
        .attachment_effects = capture.attachmentEffects(),
        .effects = capture.effects(),
    };
}

test "DeliverTabCreationHandler retires previous attachments before active resources" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const creation = try testing.create();
    var capture = captureFor(&testing, creation);
    var handler = deliveryHandler(&testing, &capture);

    try handler.execute(creation);

    try std.testing.expectEqualSlices(Event, &.{
        .{ .paste_finish = testing.previous_root },
        .{ .focus_out = testing.previous_root },
        .{ .attachment_pending = testing.previous_root },
        .{ .detach = testing.previous_root },
        .{ .retire_attachment = testing.previous_root },
        .{ .hide_graphics = testing.previous_root },
        .{ .attachment_pending = testing.previous_sibling },
        .{ .detach = testing.previous_sibling },
        .{ .retire_attachment = testing.previous_sibling },
        .{ .hide_graphics = testing.previous_sibling },
        .synchronize_active_resources,
    }, capture.eventSlice());
    try std.testing.expect(capture.committed_creation_observed);
    try std.testing.expect(capture.previous_retired_before_sync);
}

test "DeliverTabCreationHandler accepts an exact invalid-copy release" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const paste = testing.model.panePasteSession().?;
    try std.testing.expect(testing.model.finishPanePaste(paste));
    try std.testing.expect(testing.model.enterCopyMode());
    const creation = try testing.create();
    var capture = captureFor(&testing, creation);
    var handler = deliveryHandler(&testing, &capture);

    try handler.execute(creation);

    try std.testing.expect(creation.copy_released);
    try std.testing.expectEqual(creation.copy_revision_before +% 1, creation.copy_revision);
    try std.testing.expect(!testing.model.copyModeActive());
    try std.testing.expect(capture.previous_retired_before_sync);
    try std.testing.expect(capture.committed_creation_observed);
}

test "DeliverTabCreationHandler rejects altered commits before effects" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const creation = try testing.create();
    var capture = captureFor(&testing, creation);
    var handler = deliveryHandler(&testing, &capture);

    var altered = creation;
    altered.workspace_revision -%= 1;
    try std.testing.expectError(error.StaleTabCreation, handler.execute(altered));
    altered = creation;
    altered.tabs_revision -%= 1;
    try std.testing.expectError(error.StaleTabCreation, handler.execute(altered));
    altered = creation;
    altered.active_tab_revision -%= 1;
    try std.testing.expectError(error.StaleTabCreation, handler.execute(altered));
    altered = creation;
    altered.panes_revision -%= 1;
    try std.testing.expectError(error.StaleTabCreation, handler.execute(altered));
    altered = creation;
    altered.copy_revision -%= 1;
    try std.testing.expectError(error.StaleTabCreation, handler.execute(altered));
    altered = creation;
    altered.copy_revision_before -%= 1;
    try std.testing.expectError(error.StaleTabCreation, handler.execute(altered));
    altered = creation;
    altered.tabs_revision_before -%= 1;
    try std.testing.expectError(error.StaleTabCreation, handler.execute(altered));
    altered = creation;
    altered.active_tab_revision_before -%= 1;
    try std.testing.expectError(error.StaleTabCreation, handler.execute(altered));
    altered = creation;
    altered.copy_released = !altered.copy_released;
    try std.testing.expectError(error.StaleTabCreation, handler.execute(altered));
    altered = creation;
    altered.previous_layout_revision -%= 1;
    try std.testing.expectError(error.StaleTabCreation, handler.execute(altered));
    altered = creation;
    altered.created_layout_revision -%= 1;
    try std.testing.expectError(error.StaleTabCreation, handler.execute(altered));
    altered = creation;
    altered.created_root_pane_id = testing.previous_root;
    try std.testing.expectError(error.StaleTabCreation, handler.execute(altered));
    altered = creation;
    altered.created_position = 0;
    try std.testing.expectError(error.StaleTabCreation, handler.execute(altered));
    altered = creation;
    altered.previous = altered.created;
    try std.testing.expectError(error.StaleTabCreation, handler.execute(altered));

    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "DeliverTabCreationHandler catches active identity and layout ABA" {
    var identity_testing = try TestingModel.init();
    defer identity_testing.deinit();
    const identity_creation = try identity_testing.create();
    var identity_capture = captureFor(&identity_testing, identity_creation);
    var identity_handler = deliveryHandler(&identity_testing, &identity_capture);
    try std.testing.expect(identity_testing.model.workspace.select(identity_testing.previous.tab_id));

    try std.testing.expectError(error.StaleTabCreation, identity_handler.execute(identity_creation));
    try std.testing.expectEqual(@as(usize, 0), identity_capture.event_count);

    var layout_testing = try TestingModel.init();
    defer layout_testing.deinit();
    const layout_creation = try layout_testing.create();
    var layout_capture = captureFor(&layout_testing, layout_creation);
    var layout_handler = deliveryHandler(&layout_testing, &layout_capture);
    layout_testing.model.workspace.find(layout_testing.previous.tab_id).?.model.setPaneGaps(false);

    try std.testing.expectError(error.StaleTabCreation, layout_handler.execute(layout_creation));
    try std.testing.expectEqual(@as(usize, 0), layout_capture.event_count);

    var root_testing = try TestingModel.init();
    defer root_testing.deinit();
    const root_creation = try root_testing.create();
    var root_capture = captureFor(&root_testing, root_creation);
    var root_handler = deliveryHandler(&root_testing, &root_capture);
    root_testing.model.workspace.findPane(root_testing.created_root).?.attached = false;

    try std.testing.expectError(error.StaleTabCreation, root_handler.execute(root_creation));
    try std.testing.expectEqual(@as(usize, 0), root_capture.event_count);

    var pane_testing = try TestingModel.init();
    defer pane_testing.deinit();
    var pane_creation = try pane_testing.create();
    var pane_capture = captureFor(&pane_testing, pane_creation);
    var pane_handler = deliveryHandler(&pane_testing, &pane_capture);
    try pane_testing.model.workspace.active().?.model.split(.{ .existing_pane = pane_testing.created_root, .new_pane = @enumFromInt(4), .location = pane_testing.created, .axis = .vertical, .area = .{ .w = 40, .h = 10 } });
    pane_creation.created_layout_revision =
        pane_testing.model.workspace.activeConst().?.model.layout.currentRevision();

    try std.testing.expectError(error.StaleTabCreation, pane_handler.execute(pane_creation));
    try std.testing.expectEqual(@as(usize, 0), pane_capture.event_count);
}

test "DeliverTabCreationHandler stops after attachment failure without rolling back creation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const creation = try testing.create();
    var capture = captureFor(&testing, creation);
    capture.failure = .second_detach;
    var handler = deliveryHandler(&testing, &capture);

    try std.testing.expectError(error.DetachFailed, handler.execute(creation));

    try std.testing.expectEqualDeep(testing.created, testing.model.activeTabLocation().?);
    try std.testing.expect(testing.model.workspace.findPane(testing.previous_root).?.attached);
    try std.testing.expect(testing.model.workspace.findPane(testing.previous_sibling).?.attached);
    try std.testing.expect(!testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() == null);
    try std.testing.expectEqualDeep(
        Event{ .detach = testing.previous_sibling },
        capture.eventSlice()[capture.event_count - 1],
    );
    try std.testing.expect(capture.committed_creation_observed);
}

test "DeliverTabCreationHandler preserves retired attachments after resource failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const creation = try testing.create();
    var capture = captureFor(&testing, creation);
    capture.failure = .active_resources;
    var handler = deliveryHandler(&testing, &capture);

    try std.testing.expectError(error.ActiveResourcesFailed, handler.execute(creation));

    try std.testing.expectEqualDeep(testing.created, testing.model.activeTabLocation().?);
    try std.testing.expect(!testing.model.workspace.findPane(testing.previous_root).?.attached);
    try std.testing.expect(!testing.model.workspace.findPane(testing.previous_sibling).?.attached);
    try std.testing.expectEqual(
        Event.synchronize_active_resources,
        capture.eventSlice()[capture.event_count - 1],
    );
    try std.testing.expect(capture.previous_retired_before_sync);
    try std.testing.expect(capture.committed_creation_observed);
}

test "DeliverTabCreationHandler keeps completed paste retirement after focus failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const creation = try testing.create();
    var capture = captureFor(&testing, creation);
    capture.failure = .focus;
    var handler = deliveryHandler(&testing, &capture);

    try std.testing.expectError(error.FocusFailed, handler.execute(creation));

    try std.testing.expect(!testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() == null);
    try std.testing.expectEqualDeep(
        Event{ .focus_out = testing.previous_root },
        capture.eventSlice()[capture.event_count - 1],
    );
    try std.testing.expect(capture.committed_creation_observed);
}

test "DeliverTabCreationHandler stops after a failed paste boundary" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const creation = try testing.create();
    var capture = captureFor(&testing, creation);
    capture.failure = .paste;
    var handler = deliveryHandler(&testing, &capture);

    try std.testing.expectError(error.PasteFailed, handler.execute(creation));

    try std.testing.expect(!testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() != null);
    try std.testing.expect(testing.model.workspace.findPane(testing.previous_root).?.attached);
    try std.testing.expectEqualDeep(
        Event{ .paste_finish = testing.previous_root },
        capture.eventSlice()[capture.event_count - 1],
    );
    try std.testing.expect(capture.committed_creation_observed);
}
