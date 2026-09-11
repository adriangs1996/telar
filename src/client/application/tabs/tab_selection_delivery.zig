//! Application policy for delivering disposable client resources after one
//! committed tab selection.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../../workspace/root.zig");
const client_model = @import("../../root.zig").model;
const pane_focus_reporting = @import("../panes/root.zig").pane_focus_reporting;
const pane_paste = @import("../input/root.zig").pane_paste;
const tab_attachment_retirement = @import("tab_attachment_retirement.zig");

pub const schema = core.schema;
pub const tabs_mod = workspace_capability.tabs;

pub const Effects = @import("TabSelectionDeliveryEffects.zig");

pub const DeliverTabSelectionHandler = @import("DeliverTabSelectionHandler.zig");

pub const Event = union(enum) {
    paste_finish: schema.PaneId,
    focus_out: schema.PaneId,
    attachment_pending: schema.PaneId,
    detach: schema.PaneId,
    retire_attachment: schema.PaneId,
    graphics_visibility: struct {
        pane_id: schema.PaneId,
        visible: bool,
    },
    synchronize_active_resources,
    request_tab_snapshot: schema.TabLocation,
};

pub const Failure = enum {
    none,
    previous_detach,
    selected_visibility,
    active_resources,
    tab_snapshot,
};

const TestingModel = @import("TabSelectionDeliveryTestingModel.zig");

const EffectsCapture = @import("TabSelectionDeliveryEffectsCapture.zig");

fn deliveryHandler(testing: *TestingModel, capture: *EffectsCapture) DeliverTabSelectionHandler {
    return .{
        .model = testing.model,
        .paste_effects = capture.pasteEffects(),
        .focus_effects = capture.focusEffects(),
        .attachment_effects = capture.attachmentEffects(),
        .effects = capture.effects(),
    };
}

fn captureFor(testing: *TestingModel, selection: client_model.TabSelection) EffectsCapture {
    return .{
        .model = testing.model,
        .selection = selection,
        .previous_sibling = testing.previous_sibling,
        .selected_sibling = testing.selected_sibling,
    };
}

test "DeliverTabSelectionHandler retires previous resources before activating the selection" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const selection = try testing.select();
    var capture = captureFor(&testing, selection);
    var handler = deliveryHandler(&testing, &capture);

    try handler.execute(selection);

    try std.testing.expectEqualSlices(Event, &.{
        .{ .paste_finish = testing.previous_root },
        .{ .focus_out = testing.previous_root },
        .{ .attachment_pending = testing.previous_root },
        .{ .detach = testing.previous_root },
        .{ .retire_attachment = testing.previous_root },
        .{ .graphics_visibility = .{ .pane_id = testing.previous_root, .visible = false } },
        .{ .attachment_pending = testing.previous_sibling },
        .{ .detach = testing.previous_sibling },
        .{ .retire_attachment = testing.previous_sibling },
        .{ .graphics_visibility = .{ .pane_id = testing.previous_sibling, .visible = false } },
        .{ .graphics_visibility = .{ .pane_id = testing.selected_root, .visible = true } },
        .{ .graphics_visibility = .{ .pane_id = testing.selected_sibling, .visible = true } },
        .synchronize_active_resources,
        .{ .request_tab_snapshot = testing.selected },
    }, capture.eventSlice());
    try std.testing.expect(capture.committed_state_observed);
    try std.testing.expect(capture.paste_delivery_valid);
    try std.testing.expect(capture.focus_delivery_valid);
    try std.testing.expect(!testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() == null);
    try std.testing.expect(!testing.model.workspace.findPane(testing.previous_root).?.attached);
    try std.testing.expect(!testing.model.workspace.findPane(testing.previous_sibling).?.attached);
    try std.testing.expect(!testing.model.workspace.findPane(testing.selected_root).?.attached);
    try std.testing.expect(!testing.model.workspace.findPane(testing.selected_sibling).?.attached);
}

test "DeliverTabSelectionHandler rejects altered commits before resource retirement" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const selection = try testing.select();
    var capture = captureFor(&testing, selection);
    var handler = deliveryHandler(&testing, &capture);

    var wrong_revision = selection;
    wrong_revision.workspace_revision -%= 1;
    try std.testing.expectError(error.StaleTabSelection, handler.execute(wrong_revision));
    wrong_revision = selection;
    wrong_revision.tabs_revision -%= 1;
    try std.testing.expectError(error.StaleTabSelection, handler.execute(wrong_revision));
    wrong_revision = selection;
    wrong_revision.active_tab_revision -%= 1;
    try std.testing.expectError(error.StaleTabSelection, handler.execute(wrong_revision));
    wrong_revision = selection;
    wrong_revision.panes_revision -%= 1;
    try std.testing.expectError(error.StaleTabSelection, handler.execute(wrong_revision));
    wrong_revision = selection;
    wrong_revision.copy_revision -%= 1;
    try std.testing.expectError(error.StaleTabSelection, handler.execute(wrong_revision));

    var wrong_layout = selection;
    wrong_layout.previous_layout_revision -%= 1;
    try std.testing.expectError(error.StaleTabSelection, handler.execute(wrong_layout));
    wrong_layout = selection;
    wrong_layout.selected_layout_revision -%= 1;
    try std.testing.expectError(error.StaleTabSelection, handler.execute(wrong_layout));

    var repeated = selection;
    repeated.previous = repeated.selected;
    try std.testing.expectError(error.StaleTabSelection, handler.execute(repeated));

    var unknown = selection;
    unknown.previous.tab_id = @enumFromInt(99);
    try std.testing.expectError(error.StaleTabSelection, handler.execute(unknown));

    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
    try std.testing.expect(testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() != null);
}

test "DeliverTabSelectionHandler catches local layout ABA and active identity changes" {
    var previous_testing = try TestingModel.init();
    defer previous_testing.deinit();
    const previous_selection = try previous_testing.select();
    var previous_capture = captureFor(&previous_testing, previous_selection);
    var previous_handler = deliveryHandler(&previous_testing, &previous_capture);
    const previous = previous_testing.model.workspace.find(previous_testing.previous.tab_id).?;
    previous.model.setPaneGaps(false);

    try std.testing.expectError(
        error.StaleTabSelection,
        previous_handler.execute(previous_selection),
    );
    try std.testing.expectEqual(@as(usize, 0), previous_capture.event_count);

    var selected_testing = try TestingModel.init();
    defer selected_testing.deinit();
    const selected_selection = try selected_testing.select();
    var selected_capture = captureFor(&selected_testing, selected_selection);
    var selected_handler = deliveryHandler(&selected_testing, &selected_capture);
    const selected = selected_testing.model.workspace.find(selected_testing.selected.tab_id).?;
    selected.model.setPaneGaps(false);

    try std.testing.expectError(
        error.StaleTabSelection,
        selected_handler.execute(selected_selection),
    );
    try std.testing.expectEqual(@as(usize, 0), selected_capture.event_count);

    var active_testing = try TestingModel.init();
    defer active_testing.deinit();
    const active_selection = try active_testing.select();
    var active_capture = captureFor(&active_testing, active_selection);
    var active_handler = deliveryHandler(&active_testing, &active_capture);
    try std.testing.expect(active_testing.model.workspace.select(active_testing.previous.tab_id));

    try std.testing.expectError(error.StaleTabSelection, active_handler.execute(active_selection));
    try std.testing.expectEqual(@as(usize, 0), active_capture.event_count);
}

test "DeliverTabSelectionHandler stops when previous attachment retirement fails" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const selection = try testing.select();
    var capture = captureFor(&testing, selection);
    capture.failure = .previous_detach;
    var handler = deliveryHandler(&testing, &capture);

    try std.testing.expectError(error.PreviousDetachFailed, handler.execute(selection));

    try std.testing.expectEqualSlices(Event, &.{
        .{ .paste_finish = testing.previous_root },
        .{ .focus_out = testing.previous_root },
        .{ .attachment_pending = testing.previous_root },
        .{ .detach = testing.previous_root },
        .{ .retire_attachment = testing.previous_root },
        .{ .graphics_visibility = .{ .pane_id = testing.previous_root, .visible = false } },
        .{ .attachment_pending = testing.previous_sibling },
        .{ .detach = testing.previous_sibling },
    }, capture.eventSlice());
    try std.testing.expect(capture.committed_state_observed);
    try std.testing.expect(!testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() == null);
    try std.testing.expect(testing.model.workspace.findPane(testing.previous_root).?.attached);
    try std.testing.expect(testing.model.workspace.findPane(testing.previous_sibling).?.attached);
}

test "DeliverTabSelectionHandler preserves completed stages across later failures" {
    var visibility_testing = try TestingModel.init();
    defer visibility_testing.deinit();
    const visibility_selection = try visibility_testing.select();
    var visibility_capture = captureFor(&visibility_testing, visibility_selection);
    visibility_capture.failure = .selected_visibility;
    var visibility_handler = deliveryHandler(&visibility_testing, &visibility_capture);

    try std.testing.expectError(
        error.SelectedVisibilityFailed,
        visibility_handler.execute(visibility_selection),
    );
    try std.testing.expect(!visibility_testing.model.workspace.findPane(visibility_testing.previous_root).?.attached);
    try std.testing.expectEqualDeep(
        Event{ .graphics_visibility = .{
            .pane_id = visibility_testing.selected_sibling,
            .visible = true,
        } },
        visibility_capture.eventSlice()[visibility_capture.event_count - 1],
    );

    var resources_testing = try TestingModel.init();
    defer resources_testing.deinit();
    const resources_selection = try resources_testing.select();
    var resources_capture = captureFor(&resources_testing, resources_selection);
    resources_capture.failure = .active_resources;
    var resources_handler = deliveryHandler(&resources_testing, &resources_capture);

    try std.testing.expectError(
        error.ActiveResourceSynchronizationFailed,
        resources_handler.execute(resources_selection),
    );
    try std.testing.expectEqual(
        Event.synchronize_active_resources,
        resources_capture.eventSlice()[resources_capture.event_count - 1],
    );

    var snapshot_testing = try TestingModel.init();
    defer snapshot_testing.deinit();
    const snapshot_selection = try snapshot_testing.select();
    var snapshot_capture = captureFor(&snapshot_testing, snapshot_selection);
    snapshot_capture.failure = .tab_snapshot;
    var snapshot_handler = deliveryHandler(&snapshot_testing, &snapshot_capture);

    try std.testing.expectError(
        error.TabSnapshotRequestFailed,
        snapshot_handler.execute(snapshot_selection),
    );
    try std.testing.expectEqualDeep(
        Event{ .request_tab_snapshot = snapshot_testing.selected },
        snapshot_capture.eventSlice()[snapshot_capture.event_count - 1],
    );
    try std.testing.expect(visibility_capture.committed_state_observed);
    try std.testing.expect(resources_capture.committed_state_observed);
    try std.testing.expect(snapshot_capture.committed_state_observed);
}
