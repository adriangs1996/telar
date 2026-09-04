//! Application policy for delivering disposable client resources after one
//! committed tab selection.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../../../workspace/root.zig");
const client_model = @import("../../model/root.zig");
const pane_focus_reporting = @import("../panes/pane_focus_reporting.zig");
const pane_paste = @import("../input/pane_paste.zig");
const tab_attachment_retirement = @import("tab_attachment_retirement.zig");

const schema = core.schema;
const tabs_mod = workspace_capability.tabs;

pub const Effects = struct {
    context: *anyopaque,
    set_pane_graphics_visible: *const fn (*anyopaque, schema.PaneId, bool) anyerror!void,
    synchronize_active_resources: *const fn (*anyopaque) anyerror!void,
    request_tab_snapshot: *const fn (*anyopaque, schema.TabLocation) anyerror!void,
};

pub const DeliverTabSelectionHandler = struct {
    model: *client_model.Model,
    paste_effects: pane_paste.Effects,
    focus_effects: pane_focus_reporting.Effects,
    attachment_effects: tab_attachment_retirement.Effects,
    effects: Effects,

    /// Validates one exact selection before retiring the previous tab's
    /// resources and activating the selected tab's graphics and snapshot.
    ///
    /// ```zig
    /// try handler.execute(selection);
    /// ```
    pub fn execute(handler: *DeliverTabSelectionHandler, selection: client_model.TabSelection) !void {
        try handler.validate(selection);

        var retire_previous: tab_attachment_retirement.RetireTabAttachmentsHandler = .{
            .model = handler.model,
            .paste_effects = handler.paste_effects,
            .focus_effects = handler.focus_effects,
            .effects = handler.attachment_effects,
        };
        try retire_previous.execute(selection.previous);

        const selected = try handler.exactTab(selection.selected);
        var panes = selected.model.paneIterator();
        while (panes.next()) |pane| {
            try handler.effects.set_pane_graphics_visible(handler.effects.context, pane.id, true);
        }

        try handler.effects.synchronize_active_resources(handler.effects.context);
        try handler.effects.request_tab_snapshot(handler.effects.context, selection.selected);
    }

    fn validate(handler: *const DeliverTabSelectionHandler, selection: client_model.TabSelection) !void {
        if (std.meta.eql(selection.previous, selection.selected)) {
            return error.StaleTabSelection;
        }

        const previous = try handler.exactTab(selection.previous);
        const selected = try handler.exactTab(selection.selected);
        const active = handler.model.workspace.activeConst() orelse return error.StaleTabSelection;
        const version = handler.model.version();
        if (!std.meta.eql(active.location, selection.selected) or
            previous.model.layout.currentRevision() != selection.previous_layout_revision or
            selected.model.layout.currentRevision() != selection.selected_layout_revision or
            version.workspace != selection.workspace_revision or
            version.tabs != selection.tabs_revision or
            version.active_tab != selection.active_tab_revision or
            version.panes != selection.panes_revision or
            version.copy != selection.copy_revision)
        {
            return error.StaleTabSelection;
        }
    }

    fn exactTab(handler: *const DeliverTabSelectionHandler, location: schema.TabLocation) !*tabs_mod.Tab {
        const tab = handler.model.workspace.find(location.tab_id) orelse return error.StaleTabSelection;
        if (!std.meta.eql(tab.location, location)) {
            return error.StaleTabSelection;
        }

        return tab;
    }
};

const Event = union(enum) {
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

const Failure = enum {
    none,
    previous_detach,
    selected_visibility,
    active_resources,
    tab_snapshot,
};

const TestingModel = struct {
    model: *client_model.Model,
    previous: schema.TabLocation,
    selected: schema.TabLocation,
    previous_root: schema.PaneId,
    previous_sibling: schema.PaneId,
    selected_root: schema.PaneId,
    selected_sibling: schema.PaneId,

    fn init() !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
        const previous: schema.TabLocation = .{
            .workspace = workspace,
            .tab_id = @enumFromInt(1),
        };
        const selected: schema.TabLocation = .{
            .workspace = workspace,
            .tab_id = @enumFromInt(2),
        };
        const previous_root: schema.PaneId = @enumFromInt(1);
        const previous_sibling: schema.PaneId = @enumFromInt(2);
        const selected_root: schema.PaneId = @enumFromInt(3);
        const selected_sibling: schema.PaneId = @enumFromInt(4);
        const area: core.ui.Rect = .{ .w = 40, .h = 10 };
        try model.workspace.bootstrap(previous_root, previous, .{ .cols = 40, .rows = 10 });
        try model.workspace.active().?.model.split(.{ .existing_pane = previous_root, .new_pane = previous_sibling, .location = previous, .axis = .horizontal, .area = area });
        if (!model.workspace.active().?.model.focusPane(previous_root)) {
            return error.PreviousFocusNotRestored;
        }

        const root = model.workspace.findPane(previous_root).?;
        root.input_modes.bracketed_paste = true;
        root.input_modes.focus_events = true;
        _ = model.beginPanePaste().?;
        _ = model.syncReportedPaneFocus().?;

        const selected_tab = try model.workspace.addCreated(.{
            .location = selected,
            .position = 1,
            .label = "selected",
            .root_pane_id = selected_root,
        }, .{ .cols = 40, .rows = 10 });
        try selected_tab.model.split(.{ .existing_pane = selected_root, .new_pane = selected_sibling, .location = selected, .axis = .horizontal, .area = area });
        var selected_panes = selected_tab.model.paneIterator();
        while (selected_panes.next()) |pane| {
            pane.attached = false;
        }

        if (!model.workspace.select(previous.tab_id)) {
            return error.PreviousTabNotRestored;
        }

        return .{
            .model = model,
            .previous = previous,
            .selected = selected,
            .previous_root = previous_root,
            .previous_sibling = previous_sibling,
            .selected_root = selected_root,
            .selected_sibling = selected_sibling,
        };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }

    fn select(testing: *TestingModel) !client_model.TabSelection {
        return (try testing.model.selectTab(.{ .tab_id = testing.selected.tab_id })).?;
    }
};

const EffectsCapture = struct {
    model: *client_model.Model,
    selection: client_model.TabSelection,
    previous_sibling: schema.PaneId,
    selected_sibling: schema.PaneId,
    events: [20]Event = undefined,
    event_count: usize = 0,
    committed_state_observed: bool = true,
    paste_delivery_valid: bool = true,
    focus_delivery_valid: bool = true,
    failure: Failure = .none,

    fn pasteEffects(capture: *EffectsCapture) pane_paste.Effects {
        return .{ .context = capture, .deliver = deliverPaste };
    }

    fn focusEffects(capture: *EffectsCapture) pane_focus_reporting.Effects {
        return .{ .context = capture, .deliver = deliverFocus };
    }

    fn attachmentEffects(capture: *EffectsCapture) tab_attachment_retirement.Effects {
        return .{
            .context = capture,
            .attachment_pending = attachmentPending,
            .detach_pane = detachPane,
            .retire_attachment = retireAttachment,
            .hide_graphics = hideGraphics,
        };
    }

    fn effects(capture: *EffectsCapture) Effects {
        return .{
            .context = capture,
            .set_pane_graphics_visible = setPaneGraphicsVisible,
            .synchronize_active_resources = synchronizeActiveResources,
            .request_tab_snapshot = requestTabSnapshot,
        };
    }

    fn deliverPaste(context: *anyopaque, delivery: pane_paste.Delivery) !bool {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        switch (delivery) {
            .marker => |marker| {
                capture.append(.{ .paste_finish = marker.session.pane_id });
                capture.paste_delivery_valid = marker.boundary == .finish;
            },
            .content => {
                capture.paste_delivery_valid = false;
            },
        }

        return true;
    }

    fn deliverFocus(context: *anyopaque, delivery: pane_focus_reporting.Delivery) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.{ .focus_out = delivery.pane_id });
        capture.focus_delivery_valid = delivery.direction == .focus_out and
            capture.model.reportedPaneFocus() == null;
    }

    fn attachmentPending(context: *anyopaque, pane_id: schema.PaneId) bool {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.{ .attachment_pending = pane_id });

        return false;
    }

    fn detachPane(context: *anyopaque, pane_id: schema.PaneId) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.{ .detach = pane_id });
        if (capture.failure == .previous_detach and pane_id == capture.previous_sibling) {
            return error.PreviousDetachFailed;
        }
    }

    fn retireAttachment(context: *anyopaque, pane_id: schema.PaneId) void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.{ .retire_attachment = pane_id });
    }

    fn hideGraphics(context: *anyopaque, pane_id: schema.PaneId) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.{ .graphics_visibility = .{
            .pane_id = pane_id,
            .visible = false,
        } });
    }

    fn setPaneGraphicsVisible(context: *anyopaque, pane_id: schema.PaneId, visible: bool) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.{ .graphics_visibility = .{
            .pane_id = pane_id,
            .visible = visible,
        } });
        if (capture.failure == .selected_visibility and pane_id == capture.selected_sibling) {
            return error.SelectedVisibilityFailed;
        }
    }

    fn synchronizeActiveResources(context: *anyopaque) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.synchronize_active_resources);
        if (capture.failure == .active_resources) {
            return error.ActiveResourceSynchronizationFailed;
        }
    }

    fn requestTabSnapshot(context: *anyopaque, location: schema.TabLocation) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.{ .request_tab_snapshot = location });
        if (capture.failure == .tab_snapshot) {
            return error.TabSnapshotRequestFailed;
        }
    }

    fn append(capture: *EffectsCapture, event: Event) void {
        capture.committed_state_observed = capture.committed_state_observed and capture.observesSelection();
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn observesSelection(capture: *const EffectsCapture) bool {
        const previous = capture.model.workspace.find(capture.selection.previous.tab_id) orelse return false;
        const selected = capture.model.workspace.find(capture.selection.selected.tab_id) orelse return false;
        const version = capture.model.version();

        return std.meta.eql(previous.location, capture.selection.previous) and
            std.meta.eql(selected.location, capture.selection.selected) and
            std.meta.eql(capture.model.activeTabLocation(), capture.selection.selected) and
            previous.model.layout.currentRevision() == capture.selection.previous_layout_revision and
            selected.model.layout.currentRevision() == capture.selection.selected_layout_revision and
            version.workspace == capture.selection.workspace_revision and
            version.tabs == capture.selection.tabs_revision and
            version.active_tab == capture.selection.active_tab_revision and
            version.panes == capture.selection.panes_revision and
            version.copy == capture.selection.copy_revision;
    }

    fn eventSlice(capture: *const EffectsCapture) []const Event {
        return capture.events[0..capture.event_count];
    }
};

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
